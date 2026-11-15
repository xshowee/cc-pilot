// Antigravity 快照的本机存储（spec "快照与看板"持久化）：
// <HOME>/Library/Application Support/cc-pilot/antigravity-snapshots.json，与 Token 用量账本同一目录，
// 按 CoreEnvironment.home 定位（不用 FileManager 的 applicationSupportDirectory，它不看 HOME）。
//
// 启动时 load()；record 返回 needsSave 时、添加和删除之后 save(_:)。
// 读不出、不是 JSON、版本或字段不对时当作没有快照，不报错。
// 只存已添加邮箱的快照（邮箱、套餐、各组各桶的剩余与重置时间、模型列表、读取时间）和"最后读到"的邮箱；
// 没有数据的邮箱（还没读到过、格式无法识别后丢掉了数据）也存一条，重启后卡片仍在、显示同样的状态。
// 不存失败原因，不含任何凭据（看板里本来就没有 csrf token）。
//
// 文件格式（version 3）。时间是 Foundation 参考时刻（2001-01-01T00:00:00Z）起的秒数（Date 的原生表示，存取不丢精度）；
// utilization 是已用百分比（同 UsageWindow，剩余 = 100 − utilization）：
//   {"version": 3, "lastReadEmail": "…",
//    "accounts": [{"email": "…", "tierName": "Google AI Ultra", "tierId": "g1-ultra-lite-tier", "fetchedAt": 815…,
//                  "groups": [{"kind": "gemini" | "thirdParty" | "other", "displayName": "Gemini Models",
//                              "models": ["…"],
//                              "buckets": [{"bucketId": "gemini-5h", "displayName": "…", "window": "5h" | "weekly",
//                                           "usage": {"utilization": 28.88, "resetsAt": 815…}}]}]},
//                 {"email": "…", "noData": "notReadYet" | "unrecognizedFormat"}]}
// 没有的值（套餐、bucketId、桶名、usage、resetsAt、lastReadEmail）省略。没有数据的账号只有 email 和 noData：
// notReadYet 是添加后还没读到过，unrecognizedFormat 是格式无法识别丢掉了数据（fetchedAt、groups 要么都有、
// 要么都没有，有数据时没有 noData）。
// 旧版本照样能读：version 2 没有 noData，没有数据的账号都是格式无法识别；version 1 里每个账号都有数据。
// 旧版本文件里的账号（ticket 08 之前读到新邮箱就自动出现）都当作已添加。
// lastReadEmail 可以是没添加过的邮箱（刷新读到了它，但它没有卡片、没有数据）。

import Foundation

struct AntigravityBoardStore: Sendable {
    let fileURL: URL

    static let fileName = "antigravity-snapshots.json"

    init(environment: CoreEnvironment) {
        fileURL = TokenLedger.defaultURL(environment: environment).deletingLastPathComponent()
            .appendingPathComponent(Self.fileName)
    }

    /// 读出存下的看板；没有文件、读不出或格式不对时是空看板
    func load() -> AntigravityBoard {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(StoredFile.self, from: data),
              StoredFile.readableVersions.contains(file.version),
              let saved = try? file.accounts.map({ try $0.saved(version: file.version) }) else {
            return AntigravityBoard()
        }
        return AntigravityBoard(saved: saved, lastReadEmail: file.lastReadEmail)
    }

    /// 写回（原子替换），连同所在目录一起创建
    func save(_ board: AntigravityBoard) throws {
        let file = StoredFile(version: StoredFile.currentVersion, lastReadEmail: board.lastReadEmail,
                              accounts: board.saved.map(StoredAccount.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 文件格式

    private struct FormatError: Error {}

    private struct StoredFile: Codable {
        /// 2：加上没有数据的账号；3：没有数据的账号带上 noData，区分还没读到过与格式无法识别
        static let currentVersion = 3
        static let readableVersions = 1...3
        let version: Int
        let lastReadEmail: String?
        let accounts: [StoredAccount]
    }

    /// 没有数据的账号为什么没有数据（version 3 起）
    private enum NoData: String, Codable {
        /// 添加后还没读到过
        case notReadYet
        /// 格式无法识别，丢掉了数据
        case unrecognizedFormat
    }

    private struct StoredAccount: Codable {
        let email: String
        let tierName: String?
        let tierId: String?
        /// 没有数据的账号没有 fetchedAt、groups
        let fetchedAt: Date?
        let groups: [StoredGroup]?
        /// 没有数据的账号才有（version 3 起必须有）
        let noData: NoData?

        init(_ account: AntigravityBoard.SavedAccount) {
            email = account.email
            let quota = account.snapshot.quota
            tierName = quota?.tierName
            tierId = quota?.tierId
            fetchedAt = quota?.fetchedAt
            groups = quota?.groups.map(StoredGroup.init)
            switch account.snapshot {
            case .notReadYet: noData = .notReadYet
            case .discarded: noData = .unrecognizedFormat
            case .quota: noData = nil
            }
        }

        func saved(version: Int) throws -> AntigravityBoard.SavedAccount {
            let snapshot: AntigravityBoard.Snapshot
            switch (fetchedAt, groups, noData) {
            case let (fetchedAt?, groups?, nil):
                snapshot = .quota(AntigravityAccountQuota(email: email, tierName: tierName, tierId: tierId,
                                                          groups: groups.map { $0.group() }, fetchedAt: fetchedAt))
            // version 2 里没有数据的账号都是格式无法识别丢掉了数据
            case (nil, nil, nil) where version == 2:
                snapshot = .discarded
            case (nil, nil, .notReadYet?) where version >= 3:
                snapshot = .notReadYet
            case (nil, nil, .unrecognizedFormat?) where version >= 3:
                snapshot = .discarded
            default:
                throw FormatError()
            }
            return AntigravityBoard.SavedAccount(email: email, snapshot: snapshot)
        }
    }

    private struct StoredGroup: Codable {
        /// 不认识的类别解不出来，整个文件当作格式不对
        let kind: AntigravityQuotaGroup.Kind
        let displayName: String
        let models: [String]
        let buckets: [StoredBucket]

        init(_ group: AntigravityQuotaGroup) {
            kind = group.kind
            displayName = group.displayName
            models = group.models
            buckets = group.buckets.map(StoredBucket.init)
        }

        func group() -> AntigravityQuotaGroup {
            AntigravityQuotaGroup(kind: kind, displayName: displayName, models: models,
                                  buckets: buckets.map { $0.bucket() })
        }
    }

    private struct StoredBucket: Codable {
        let bucketId: String?
        let displayName: String?
        /// 不认识的窗口解不出来，整个文件当作格式不对
        let window: AntigravityQuotaBucket.Window
        let usage: StoredUsage?

        init(_ bucket: AntigravityQuotaBucket) {
            bucketId = bucket.bucketId
            displayName = bucket.displayName
            window = bucket.window
            usage = bucket.usage.map { StoredUsage(utilization: $0.utilization, resetsAt: $0.resetsAt) }
        }

        func bucket() -> AntigravityQuotaBucket {
            AntigravityQuotaBucket(bucketId: bucketId, displayName: displayName, window: window,
                                   usage: usage.map { UsageWindow(utilization: $0.utilization, resetsAt: $0.resetsAt) })
        }
    }

    private struct StoredUsage: Codable {
        let utilization: Double
        let resetsAt: Date?
    }
}
