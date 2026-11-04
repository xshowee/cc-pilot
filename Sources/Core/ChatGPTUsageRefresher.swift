// 刷新 ChatGPT 额度（chatgpt-profiles ticket 07，spec "手动刷新（API 契约）"）。与 Claude 一侧的 UsageRefresher 并列。
//
// 用法（只在用户点"全部刷新"或某个 ChatGPT 账号的刷新按钮时调用；在后台队列上调用，会阻塞）：
//   let refresher = ChatGPTUsageRefresher(environment: env)
//   refresher.refreshAll(profiles, now: Date())             → 每个账号一个结果
//   refresher.refresh(account, in: profiles, now: Date())   → 只刷新一个账号
// 结果里的 outcome 交给 UsageBoard.record(_:)（与 Claude 共用一个看板，账号键带 "chatgpt:" 前缀，不会相撞）；
// reported 是响应里的套餐，界面用它更新套餐标记。
//
// 规则：
// - 额度属于账号：账号 = 用户 ID + 工作区 ID（ChatGPTAccountKey）。登录同一账号的多个档案只请求一次；
//   同一工作区的不同用户各请求一次。没有账号的档案（未登录、API key、读不懂）不请求。
// - 发请求前用 ChatGPTProfileStore.usageAuthorization 重新读取 auth.json，只有"可以请求额度"才发；
//   同一账号的几个档案里，取第一个可以请求的档案的凭据。凭据用完即丢；不续期、不写 auth.json。
// - 请求头只有 Authorization、ChatGPT-Account-Id、User-Agent（如实标明 cc-pilot，不冒充官方客户端）。
// - 窗口按 limit_window_seconds 识别（18000 = 5 小时窗口，604800 = 周窗口），不按 primary / secondary 的位置猜；
//   其他长度的窗口不显示。
// - 失败的处理同 Claude 一侧：401 → 待续期；403 / 429 → 频率限制；其他状态码、网络失败、格式无法识别同样记录。
//
// 登录状态的映射：UsageFetchResult / UsageProblem 里的登录状态是 Claude 的 LoginStatus（与 Claude 共用看板）。
// ChatGPT 一侧用 ChatGPTLoginStatus.usageProblemStatus 映射过去：待续期 → .needsRenewal，未登录 → .notLoggedIn，
// API key → .usageUnsupported，读不懂 → .accountUnreadable。只有已登录 ChatGPT 的档案才有账号，所以实际只会出现
// 待续期（发请求前过期，或 401）和刷新前刚被登出等少见情形。界面上 ChatGPT 行的失败原因要用 ChatGPT 的文字显示
// （Claude 的提示会让用户去打开 claude）。
//
// email、plan_type："校验并更新显示"。响应的 email 与 auth.json 的邮箱都有且不同（不区分大小写）时，
// 不采用响应里的套餐（这份响应说的是另一个账号），额度照常采用（请求用的就是这个档案的令牌和工作区 ID）；
// 显示的邮箱始终来自 auth.json。待真机验证（ticket 13）。

import Foundation

extension ChatGPTAccountKey {
    /// 这个账号在额度看板（以及之后的 Token 用量账本）里的键。前缀与 Claude 的 "account:" / "profile:" 区分开；
    /// 用户 ID 与工作区 ID 都参与，同一工作区的不同用户是不同账号。
    var usageAccount: UsageAccount { UsageAccount(id: "chatgpt:" + userID + ":" + workspaceID) }
}

extension ChatGPTProfile {
    /// 这个档案登录的账号；未登录、API key、读不懂、或缺用户 ID / 工作区 ID 时为 nil（不参与刷新）
    var usageAccount: UsageAccount? { account?.key?.usageAccount }
}

extension UsageBoard {
    /// 这个 ChatGPT 档案所在账号的额度状态；还没有数据、或档案没有账号时为 nil
    func usage(for profile: ChatGPTProfile) -> AccountUsage? {
        profile.usageAccount.flatMap { usage(for: $0) }
    }
}

extension ChatGPTLoginStatus {
    /// 记在额度看板里的登录状态（见文件头"登录状态的映射"）
    var usageProblemStatus: LoginStatus {
        switch self {
        case .notLoggedIn: return .notLoggedIn
        case .needsRenewal: return .needsRenewal
        case .canRequestUsage: return .canRequestUsage
        case .apiKey: return .usageUnsupported
        case .incompatible: return .accountUnreadable
        }
    }
}

/// 响应里说的账号资料（只在成功时有）
struct ChatGPTReportedAccount: Equatable {
    /// 套餐（plan_type），原样保存；与 auth.json 的邮箱对不上时为 nil
    let planType: String?
}

/// 一个 ChatGPT 账号的一次刷新结果
struct ChatGPTUsageRefreshOutcome: Equatable {
    /// 交给 UsageBoard.record(_:)
    let outcome: UsageRefreshOutcome
    /// 响应里的账号资料；没成功时为 nil
    let reported: ChatGPTReportedAccount?

    var account: UsageAccount { outcome.account }
}

struct ChatGPTUsageRefresher: Sendable {
    static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// 单次请求的超时（同 Claude 一侧）
    static let timeout: TimeInterval = UsageRefresher.timeout

    let environment: CoreEnvironment

    init(environment: CoreEnvironment = .live) {
        self.environment = environment
    }

    /// 列表里的账号，按第一次出现的顺序，不重复
    static func accounts(in profiles: [ChatGPTProfile]) -> [UsageAccount] {
        var seen: Set<UsageAccount> = []
        return profiles.compactMap(\.usageAccount).filter { seen.insert($0).inserted }
    }

    /// "全部刷新"：每个账号请求一次（逐个进行）
    func refreshAll(_ profiles: [ChatGPTProfile], now: Date = Date()) -> [ChatGPTUsageRefreshOutcome] {
        Self.accounts(in: profiles).map { refresh($0, in: profiles, now: now) }
    }

    /// 刷新一个账号
    func refresh(_ account: UsageAccount, in profiles: [ChatGPTProfile], now: Date = Date()) -> ChatGPTUsageRefreshOutcome {
        let store = ChatGPTProfileStore(environment: environment)
        var firstDenial: ChatGPTLoginStatus?
        for profile in profiles where profile.usageAccount == account {
            switch store.usageAuthorization(for: profile, now: now) {
            case .granted(let credential):
                let (result, reported) = fetch(credential, email: profile.account?.email, now: now)
                return ChatGPTUsageRefreshOutcome(outcome: UsageRefreshOutcome(account: account, result: result),
                                                  reported: reported)
            case .denied(let status):
                firstDenial = firstDenial ?? status
            }
        }
        let status = (firstDenial ?? .notLoggedIn).usageProblemStatus
        return ChatGPTUsageRefreshOutcome(outcome: UsageRefreshOutcome(account: account, result: .denied(status)),
                                          reported: nil)
    }

    // MARK: - 内部

    private func fetch(_ credential: ChatGPTUsageCredential, email: String?,
                       now: Date) -> (UsageFetchResult, ChatGPTReportedAccount?) {
        var request = URLRequest(url: Self.usageEndpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("cc-pilot/" + environment.appVersion, forHTTPHeaderField: "User-Agent")

        guard let response = try? environment.transport.send(request) else { return (.networkFailure, nil) }
        switch response.status {
        case 200:
            break
        case 401:
            // 只有 access token 未过期才会发请求；被拒绝就按待续期处理：在该档案里打开一次 codex 或 ChatGPT 即可恢复。
            // cc-pilot 不续期。
            return (.unauthorized(.needsRenewal), nil)
        case 403, 429:
            return (.rateLimited(until: UsageRateLimit.retryAt(retryAfter: response.headers["retry-after"], now: now)),
                    nil)
        default:
            return (.httpStatus(response.status), nil)
        }
        guard let parsed = ChatGPTUsageResponse(json: response.body, fetchedAt: now) else {
            return (.unrecognizedFormat, nil)
        }
        return (.success(parsed.snapshot), parsed.reported(matching: email))
    }
}

/// wham/usage 的响应（只取 spec 列出的字段）
struct ChatGPTUsageResponse {
    /// 5 小时窗口的长度（秒）
    static let fiveHourSeconds = 18_000
    /// 周窗口的长度（秒）
    static let weekSeconds = 604_800

    let snapshot: UsageSnapshot
    let email: String?
    let planType: String?

    /// 解析响应体。不是 JSON 对象、或 rate_limit 既不是对象也不是 null（包括缺失）时返回 nil（格式无法识别）。
    /// rate_limit 为 null 时没有窗口；窗口按 limit_window_seconds 识别，used_percent 或长度不是数字的窗口不显示。
    init?(json data: Data, fetchedAt: Date) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var windows: [Int: UsageWindow] = [:]
        switch root["rate_limit"] {
        case let rateLimit as [String: Any]:
            for key in ["primary_window", "secondary_window"] {
                guard let object = rateLimit[key] as? [String: Any],
                      let used = UsageSnapshot.number(object["used_percent"]),
                      let seconds = UsageSnapshot.number(object["limit_window_seconds"]) else { continue }
                let length = Int(seconds)
                if windows[length] == nil {
                    windows[length] = UsageWindow(utilization: used, resetsAt: UsageSnapshot.date(object["reset_at"]))
                }
            }
        case is NSNull:
            break
        default:
            return nil
        }
        snapshot = UsageSnapshot(fiveHour: windows[Self.fiveHourSeconds], sevenDay: windows[Self.weekSeconds],
                                 fetchedAt: fetchedAt)
        email = root["email"] as? String
        planType = root["plan_type"] as? String
    }

    /// 响应里的套餐；响应的邮箱与 auth.json 的邮箱都有且不同时不采用（见 ChatGPTUsageRefresher 文件头）
    func reported(matching authEmail: String?) -> ChatGPTReportedAccount {
        if let email, let authEmail, email.lowercased() != authEmail.lowercased() {
            return ChatGPTReportedAccount(planType: nil)
        }
        return ChatGPTReportedAccount(planType: planType)
    }
}
