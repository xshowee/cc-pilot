// Antigravity 看板（spec "快照与看板"）：用户添加的每个邮箱最后一次读到的额度（快照），以及每张卡片此刻怎么显示。
// 纯逻辑：不碰进程、不联网，所以打开面板、启动 App 都不会触发读取。持久化见 AntigravityBoardStore。
//
// 界面持有一个看板：AntigravityRefresher 的结果交给 record(_:clicked:)（clicked 是被点的卡片的邮箱，
// 按点的顺序；"刷新全部"且没有点卡片时为空），面板按 cards(now:) 画。
// 一次只读一次（AntigravityRefreshing）：读取进行中再点别的卡片不发起新的读取，那张卡片也算被点的卡片。
//
// 添加（ticket 08）：账号由用户手动添加（输入邮箱，add），读到新邮箱不会自动出现。添加不读 Antigravity；
// 输入先去掉首尾空白，空的、不像邮箱的（要有 @、两边非空、不含空白）、已添加的不能添加，problem(forNewEmail:)
// 给出原因供表单实时提示。新卡片排在最后，还没读到过：没有问题、没有组、没有读取时间（isNotReadYet）。
// 已添加邮箱的匹配一律不分大小写（刷新结果、被点卡片、删除）；卡片保持添加时的写法。
//
// 并入规则（ticket 02、08）：
//   success（已添加）       → 直接替换旧快照（不合并）；记为"最后读到"；清掉这个邮箱的原因，
//                            以及不知道是哪个账号时落下的原因（未登录等是 App 的状态，读到账号后就不成立了）
//   success（没添加）       → 不建卡片、不存它的数据；仍记为"最后读到"（已添加的卡片都成了旧快照，没有"当前"），
//                            同样清掉不知道是哪个账号时落下的原因
//   unrecognizedFormat(邮箱) → 丢掉这个邮箱的快照数据（还没读到过的也算），卡片留着（也存下来，重启后仍在）、
//                            显示"接口可能已变化"，直到这个邮箱下次成功：丢掉了数据的卡片没有别的原因时一律显示它
//   unrecognizedFormat(nil)  → 不丢任何快照，原因落在"不知道是哪个账号"的卡片（见下）
//   failed(邮箱?, 原因)      → 保留快照，记原因；落在读到的邮箱，没有邮箱时落在"不知道是哪个账号"的卡片
//   notSignedIn             → 原因"Antigravity 未登录"落在"不知道是哪个账号"的卡片
//   appNotRunning           → 什么都不改；被点的卡片得到短暂提示，"刷新全部"时没有提示
// "不知道是哪个账号"的卡片：第一张被点的卡片（发起读取的那张）；没有被点的卡片（"刷新全部"）时为最后读到的邮箱
// （它没添加过时没有这张卡片，原因不记）。
// 读到的邮箱没添加过时，失败与格式无法识别的原因同样落在这张卡片上。
// 读到的邮箱与被点卡片不同：被点卡片得到短暂提示"Antigravity 里登录的是 <邮箱>"（不只成功时，没添加过的邮箱也给）。
// 短暂提示给每张被点的卡片各算一次；读取期间被删掉的卡片没有提示。
// 短暂提示由 record 返回、不存在看板里：显示多久是界面的事（同 KimiModel.copyNotice）。
//
// 显示：最后读到的邮箱正常显示；其他邮箱是旧快照，整体变灰并显示读取时间。
// 每个窗口的显示（剩余、"已重置，待刷新"、颜色阈值）用 UsageReading；旧快照的数字一律变灰。
// 组按接口顺序；同一组里 5 小时窗口排在周窗口前（同 Claude Code、Kimi Code 卡片），同类窗口之间保持接口顺序。
// 同一组里同一窗口类型出现多次时，第二个起带区分标签（facts.md：桶名，没有时 bucketId），卡片与统计面板共用。
// 卡片按添加的顺序排列（刷新不会让卡片换位置）。
// 删除（remove）：从看板删掉这个邮箱和快照，之后再读到同一邮箱也不会重新出现，要再手动添加。

import Foundation

/// 卡片上显示的最近一次刷新的问题
enum AntigravityProblem: Equatable, Sendable {
    /// 刷新失败（保留快照）
    case failed(AntigravityRefreshFailure)
    /// 接口可能已变化
    case unrecognizedFormat
    /// Antigravity 未登录
    case notSignedIn
}

/// 一次刷新后给某张卡片的短暂提示
struct AntigravityNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// "打开 Antigravity 后可刷新"
        case openAppToRefresh
        /// "Antigravity 里登录的是 <邮箱>"
        case signedInAs(String)
    }

    /// 显示提示的卡片（邮箱）
    let card: String
    let kind: Kind
}

/// record(_:clicked:) 的结果
struct AntigravityRecordEffect: Equatable, Sendable {
    /// 要给被点的卡片的短暂提示，按点的顺序，每张卡片至多一条
    var notices: [AntigravityNotice]
    /// 要存的内容变了，需要写回（AntigravityBoardStore.save）
    var needsSave: Bool
}

/// 一张卡片此刻怎么显示
struct AntigravityCard: Equatable, Sendable {
    let email: String
    /// 套餐标签（如 "Google AI Ultra"）；没有快照、或接口没给时为 nil。套餐 id 只存在快照里，界面不用
    let tierName: String?
    /// 不是最后读到的邮箱：整体变灰并显示"上次读取：<fetchedAt>"
    let isOldSnapshot: Bool
    /// 添加后还没读到过（最下面一行显示"尚未读取"）
    let isNotReadYet: Bool
    /// 快照的读取时间；没有快照数据（还没读到过、格式无法识别后）时为 nil
    let fetchedAt: Date?
    /// 最近一次落在这张卡片上的问题；格式无法识别丢掉了数据的卡片没有别的问题时是"接口可能已变化"
    /// （还没读到过的不是）；没有时为 nil
    let problem: AntigravityProblem?
    /// 按接口顺序的组；没有快照数据时为空
    let groups: [AntigravityGroupDisplay]
}

struct AntigravityGroupDisplay: Equatable, Sendable {
    let kind: AntigravityQuotaGroup.Kind
    /// 接口原名（kind 为 other 时照搬显示）
    let displayName: String
    let models: [String]
    /// 5 小时窗口在前、周窗口在后（同类之间按接口顺序），每个一行 / 一个圆环
    let buckets: [AntigravityBucketDisplay]
}

struct AntigravityBucketDisplay: Equatable, Sendable {
    let bucketId: String?
    let displayName: String?
    let window: AntigravityQuotaBucket.Window
    /// 同一组里这个窗口类型不是第一次出现时，行标签 / 圆环标签后加上的区分文字：桶名，没有时 bucketId，
    /// 都没有时为 nil。第一次出现的为 nil（只显示"5 小时窗口""周窗口"）
    let extraLabel: String?
    /// 剩余、"已重置，待刷新"、"—"及颜色（旧快照一律变灰）
    let reading: UsageReading
    /// 重置时间（倒计时用）；没有数字时为 nil
    let resetsAt: Date?
}

struct AntigravityBoard: Equatable, Sendable {
    /// 一个已添加的邮箱有没有数据
    enum Snapshot: Equatable, Sendable {
        /// 添加后还没读到过
        case notReadYet
        /// 格式无法识别，丢掉了数据（卡片显示"接口可能已变化"）
        case discarded
        case quota(AntigravityAccountQuota)

        var quota: AntigravityAccountQuota? {
            if case .quota(let quota) = self { return quota }
            return nil
        }
    }

    private struct Entry: Equatable, Sendable {
        /// 添加时输入的写法（卡片、提示、统计面板都按它）
        let email: String
        var snapshot: Snapshot
        var problem: AntigravityProblem?
        /// problem 不是这个账号自己的（不知道是哪个账号时落在这里）：任一邮箱成功时清掉
        var problemIsAccountless = false
    }

    /// 按添加的顺序
    private var entries: [Entry] = []
    /// 最后一次成功读到的邮箱（可以是没添加过的邮箱）
    private(set) var lastReadEmail: String?

    init() {}

    /// 存下的一个邮箱（AntigravityBoardStore）
    struct SavedAccount: Equatable, Sendable {
        let email: String
        let snapshot: Snapshot
    }

    /// 从存下的内容恢复（AntigravityBoardStore.load）：按给的顺序，没有失败原因
    init(saved: [SavedAccount], lastReadEmail: String?) {
        entries = saved.map { Entry(email: $0.email, snapshot: $0.snapshot, problem: nil) }
        self.lastReadEmail = lastReadEmail
    }

    /// 各卡片的邮箱，按卡片顺序（含没有快照数据的卡片）
    var emails: [String] { entries.map(\.email) }

    /// 要存下的内容（按卡片顺序）：每张卡片的快照，没有数据的卡片也存（区分还没读到过与格式无法识别，
    /// 重启后照样显示）；失败原因不存
    var saved: [SavedAccount] {
        entries.map { SavedAccount(email: $0.email, snapshot: $0.snapshot) }
    }

    // MARK: - 添加

    /// 要添加的邮箱的问题（添加表单据此实时提示）
    enum NewEmailProblem: Equatable, Sendable {
        /// 还没输入（不提示）
        case empty
        /// 不像邮箱：要有 @、两边非空、不含空白
        case malformed
        /// 已添加（不分大小写）
        case exists
    }

    /// 输入的邮箱有什么问题（先去掉首尾空白）；可以添加时为 nil
    func problem(forNewEmail input: String) -> NewEmailProblem? {
        let email = Self.trimmedEmail(input)
        if email.isEmpty { return .empty }
        guard let at = email.firstIndex(of: "@"), at != email.startIndex, email.index(after: at) != email.endIndex,
              !email.contains(where: \.isWhitespace) else { return .malformed }
        if index(of: email) != nil { return .exists }
        return nil
    }

    /// 添加一个邮箱（去掉首尾空白）：卡片排在最后，还没读到过，之后要写回。有问题时什么都不做，返回 false。
    /// 添加不读 Antigravity
    @discardableResult
    mutating func add(_ input: String) -> Bool {
        guard problem(forNewEmail: input) == nil else { return false }
        entries.append(Entry(email: Self.trimmedEmail(input), snapshot: .notReadYet, problem: nil))
        return true
    }

    /// 标准化邮箱（去首尾空白、转小写、非空且含 "@"）；为空或不含 "@" 时返回 nil
    static func normalizedEmail(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty, trimmed.contains("@") else {
            return nil
        }
        return trimmed
    }

    private static func trimmedEmail(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 并入一次刷新的结果（规则见文件头）。clicked 是被点的卡片的邮箱，"刷新全部"时为 nil
    @discardableResult
    mutating func record(_ result: AntigravityRefreshResult, clicked: String?) -> AntigravityRecordEffect {
        record(result, clicked: clicked.map { [$0] } ?? [])
    }

    /// 并入一次刷新的结果（规则见文件头）。clicked 是被点的卡片，按点的顺序（AntigravityRefreshing.finish）
    @discardableResult
    mutating func record(_ result: AntigravityRefreshResult, clicked cards: [String]) -> AntigravityRecordEffect {
        var effect = AntigravityRecordEffect(notices: [], needsSave: false)
        for card in cards where index(of: card) != nil {
            if case .appNotRunning = result {
                effect.notices.append(AntigravityNotice(card: card, kind: .openAppToRefresh))
            } else if let email = result.email, !Self.same(email, card) {
                effect.notices.append(AntigravityNotice(card: card, kind: .signedInAs(email)))
            }
        }
        let clicked = cards.first
        switch result {
        case .appNotRunning:
            break
        case .notSignedIn:
            land(.notSignedIn, email: nil, clicked: clicked)
        case .failed(let email, let reason):
            land(.failed(reason), email: email, clicked: clicked)
        case .unrecognizedFormat(let email):
            if let email, let index = index(of: email), entries[index].snapshot != .discarded {
                entries[index].snapshot = .discarded
                effect.needsSave = true
            }
            land(.unrecognizedFormat, email: email, clicked: clicked)
        case .success(let quota):
            _ = recordPassive(quota)
            effect.needsSave = true
        }
        return effect
    }

    /// 并入一次被动收到的额度结果（仅消费成功快照；不产生短暂提示、不写 problem、不丢弃快照）
    @discardableResult
    mutating func recordPassive(_ quota: AntigravityAccountQuota) -> Bool {
        let clearedProblem = clearAccountlessProblems()
        if let index = index(of: quota.email) {
            // 卡片保持添加时的写法：快照里的邮箱也用它（存下、读回不变）
            let email = entries[index].email
            entries[index] = Entry(email: email, snapshot: .quota(quota.withEmail(email)), problem: nil)
            lastReadEmail = email
            return true
        }
        // 没添加过的邮箱：不建卡片、不存它的数据，只记为"最后读到"（已添加的卡片都变成旧快照）
        let lastReadChanged = lastReadEmail != quota.email
        lastReadEmail = quota.email
        return lastReadChanged || clearedProblem
    }

    @discardableResult
    private mutating func clearAccountlessProblems() -> Bool {
        var cleared = false
        for index in entries.indices where entries[index].problemIsAccountless {
            entries[index].problem = nil
            entries[index].problemIsAccountless = false
            cleared = true
        }
        return cleared
    }

    /// 把原因记到读到的邮箱的卡片；没有邮箱、或这个邮箱没添加过时，记到被点的卡片（"刷新全部"时最后读到的）。
    /// 哪张都没有时不记。
    private mutating func land(_ problem: AntigravityProblem, email: String?, clicked: String?) {
        if let email, let index = index(of: email) {
            entries[index].problem = problem
            entries[index].problemIsAccountless = false
        } else if let fallback = clicked ?? lastReadEmail, let index = index(of: fallback) {
            entries[index].problem = problem
            entries[index].problemIsAccountless = true
        }
    }

    /// 这个邮箱的统计重置时间锚点：按 Gemini -> Argon -> Carbon -> Claude & GPT 池优先级
    /// 分别挑选 5 小时与周重置时间；没有快照或对应窗口缺失时为 nil（由统计回落到滚动窗口）。
    func knownResets(for email: String) -> KnownResets {
        guard let index = index(of: email), let quota = entries[index].snapshot.quota else {
            return KnownResets(fiveHour: nil, sevenDay: nil)
        }
        var fiveHour: Date?
        var sevenDay: Date?
        for rank in 0...3 {
            for group in quota.groups where Self.poolRank(of: group) == rank {
                if fiveHour == nil {
                    fiveHour = group.buckets.first { $0.window == .fiveHour && $0.usage?.resetsAt != nil }?.usage?.resetsAt
                }
                if sevenDay == nil {
                    sevenDay = group.buckets.first { $0.window == .weekly && $0.usage?.resetsAt != nil }?.usage?.resetsAt
                }
            }
        }
        return KnownResets(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func poolRank(of group: AntigravityQuotaGroup) -> Int? {
        switch group.kind {
        case .gemini:
            return 0
        case .thirdParty:
            return 3
        case .other:
            let name = group.displayName
            if name.localizedCaseInsensitiveContains("argon") { return 1 }
            if name.localizedCaseInsensitiveContains("carbon") { return 2 }
            return nil
        }
    }

    /// 删除这个邮箱的卡片和快照（不分大小写，之后要写回）。之后再读到同一邮箱不会重新出现。删的是最后读到的邮箱时，
    /// 剩下的卡片都是旧快照。
    mutating func remove(_ email: String) {
        entries.removeAll { Self.same($0.email, email) }
        if let last = lastReadEmail, Self.same(last, email) { lastReadEmail = nil }
    }

    /// 各卡片此刻怎么显示，按添加的顺序；没有卡片时为空（面板不显示 Antigravity 一段）
    func cards(now: Date) -> [AntigravityCard] {
        entries.map { entry in
            let old = !isLastRead(entry.email)
            let quota = entry.snapshot.quota
            return AntigravityCard(
                email: entry.email, tierName: quota?.tierName, isOldSnapshot: old,
                isNotReadYet: entry.snapshot == .notReadYet, fetchedAt: quota?.fetchedAt,
                problem: entry.problem ?? (entry.snapshot == .discarded ? .unrecognizedFormat : nil),
                groups: quota.map { quota in
                    quota.groups.map { Self.display($0, fetchedAt: quota.fetchedAt, old: old, now: now) }
                } ?? [])
        }
    }

    private static func display(_ group: AntigravityQuotaGroup, fetchedAt: Date, old: Bool,
                                now: Date) -> AntigravityGroupDisplay {
        // 5 小时窗口在前、周窗口在后，各自保持接口顺序（不用 sorted：它不保证稳定）
        let ordered = group.buckets.filter { $0.window == .fiveHour } + group.buckets.filter { $0.window == .weekly }
        let buckets = ordered.enumerated().map { index, bucket in
            let repeated = ordered[..<index].contains { $0.window == bucket.window }
            return AntigravityBucketDisplay(
                bucketId: bucket.bucketId, displayName: bucket.displayName, window: bucket.window,
                extraLabel: repeated ? bucket.displayName ?? bucket.bucketId : nil,
                reading: reading(bucket.usage, fetchedAt: fetchedAt, old: old, now: now),
                resetsAt: bucket.usage?.resetsAt)
        }
        return AntigravityGroupDisplay(kind: group.kind, displayName: group.displayName, models: group.models,
                                       buckets: buckets)
    }

    private static func reading(_ window: UsageWindow?, fetchedAt: Date, old: Bool, now: Date) -> UsageReading {
        let reading = UsageReading(window, fetchedAt: fetchedAt, now: now)
        if old, case .remaining(let percent, _) = reading { return .remaining(percent, tint: .stale) }
        return reading
    }

    /// 已添加邮箱的匹配一律不分大小写
    private func index(of email: String) -> Int? {
        entries.firstIndex { Self.same($0.email, email) }
    }

    private func isLastRead(_ email: String) -> Bool {
        lastReadEmail.map { Self.same($0, email) } ?? false
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }
}

/// Antigravity 的读取一次只进行一次：每张卡片读到的都是 App 里当前登录的同一个账号。
/// 读取进行中再点别的卡片不发起新的读取，那张卡片也转圈，读取结束后同样按被点的卡片得到提示
/// （AntigravityBoard.record(_:clicked:)）。界面（AntigravityModel）持有一个。
struct AntigravityRefreshing: Equatable, Sendable {
    /// 被点的卡片（邮箱），按点的顺序；第一张是发起读取的（"刷新全部"发起时可能为空）
    private var clicked: [String] = []
    private var refreshAll = false
    /// 有一次读取在进行
    private(set) var isRunning = false

    init() {}

    /// 点了这张卡片的刷新。返回 true 时要发起一次读取；读取已在进行时加入它，返回 false
    mutating func click(_ email: String) -> Bool {
        if !clicked.contains(email) { clicked.append(email) }
        defer { isRunning = true }
        return !isRunning
    }

    /// 点了"刷新全部"。返回 true 时要发起一次读取；读取已在进行时什么都不做，返回 false
    mutating func clickRefreshAll() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        refreshAll = true
        return true
    }

    /// 这张卡片显示转圈：它被点过，或读取由"刷新全部"发起
    func isSpinning(_ email: String) -> Bool {
        isRunning && (refreshAll || clicked.contains(email))
    }

    /// 读取结束：返回被点的卡片（按点的顺序），交给 AntigravityBoard.record(_:clicked:)
    mutating func finish() -> [String] {
        defer { self = AntigravityRefreshing() }
        return clicked
    }
}

private extension AntigravityAccountQuota {
    /// 同一份数据，邮箱换成卡片的写法（读到的邮箱只与卡片差在大小写）
    func withEmail(_ email: String) -> AntigravityAccountQuota {
        AntigravityAccountQuota(email: email, tierName: tierName, tierId: tierId, groups: groups, fetchedAt: fetchedAt)
    }
}
