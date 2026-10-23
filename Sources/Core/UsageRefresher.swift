// 刷新额度：按账号向额度接口发请求（spec "额度接口"、"刷新与界面"）。
//
// 用法（只在用户点"刷新全部"或某个账号的刷新按钮时调用；在后台队列上调用，会阻塞）：
//   let refresher = UsageRefresher(environment: env)
//   refresher.refreshAll(profiles, now: Date())             → 每个账号一个结果
//   refresher.refresh(account, in: profiles, now: Date())   → 只刷新一个账号
// 结果交给 UsageBoard.record(_:) 保存，界面从 UsageBoard 读。
//
// 规则：
// - 额度属于账号：登录同一账号（accountUuid 相同）的多个档案只请求一次，结果共用。
// - 发请求前用 LoginChecker.usageAuthorization 重新读取凭据，只有"可以请求额度"才发；
//   同一账号的几个档案里，取第一个可以请求的档案的凭据。凭据用完即丢。
// - 请求头如实标明 cc-pilot，不冒充官方客户端。

import Foundation

/// 额度所属的账号。按 accountUuid 识别；已登录却没有 accountUuid 的档案无法与别的档案合并，单独算一个账号。
struct UsageAccount: Hashable, CustomStringConvertible {
    let id: String
    var description: String { id }
}

extension Profile {
    /// 这个档案登录的账号；未登录或 .claude.json 读不出来时为 nil（不参与刷新）
    var usageAccount: UsageAccount? {
        guard let account = account.account else { return nil }
        if let uuid = account.accountUuid { return UsageAccount(id: "account:" + uuid) }
        return UsageAccount(id: "profile:" + name)
    }
}

/// 一个账号的一次获取结果
enum UsageFetchResult: Equatable {
    case success(UsageSnapshot)
    /// 没有发请求：没有一个档案处于"可以请求额度"（附带第一个档案的状态）
    case denied(LoginStatus)
    /// 接口返回了 200 以外的状态码（retryAfter 是 retry-after 响应头的原文）
    case httpStatus(Int, retryAfter: String?)
    /// 网络失败或超时
    case networkFailure
    /// 响应不是 JSON 对象，或一个已知的顶层字段都没有
    case unrecognizedFormat

    var snapshot: UsageSnapshot? {
        if case .success(let snapshot) = self { return snapshot }
        return nil
    }
}

struct UsageRefreshOutcome: Equatable {
    let account: UsageAccount
    let result: UsageFetchResult
}

struct UsageRefresher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// 单次请求的超时（Claude Code 自己用 5 秒）
    static let timeout: TimeInterval = 5

    let environment: CoreEnvironment

    init(environment: CoreEnvironment = .live) {
        self.environment = environment
    }

    /// 列表里的账号，按第一次出现的顺序，不重复
    static func accounts(in profiles: [Profile]) -> [UsageAccount] {
        var seen: Set<UsageAccount> = []
        return profiles.compactMap(\.usageAccount).filter { seen.insert($0).inserted }
    }

    /// "刷新全部"：每个账号请求一次（逐个进行）
    func refreshAll(_ profiles: [Profile], now: Date = Date()) -> [UsageRefreshOutcome] {
        Self.accounts(in: profiles).map { refresh($0, in: profiles, now: now) }
    }

    /// 刷新一个账号
    func refresh(_ account: UsageAccount, in profiles: [Profile], now: Date = Date()) -> UsageRefreshOutcome {
        let checker = LoginChecker(environment: environment)
        var firstDenial: LoginStatus?
        for profile in profiles where profile.usageAccount == account {
            switch checker.usageAuthorization(for: profile, now: now) {
            case .granted(let credential):
                return UsageRefreshOutcome(account: account, result: fetch(credential, now: now))
            case .denied(let status):
                firstDenial = firstDenial ?? status
            }
        }
        return UsageRefreshOutcome(account: account, result: .denied(firstDenial ?? .notLoggedIn))
    }

    // MARK: - 内部

    private func fetch(_ credential: UsageCredential, now: Date) -> UsageFetchResult {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cc-pilot/" + environment.appVersion, forHTTPHeaderField: "User-Agent")

        guard let response = try? environment.transport.send(request) else { return .networkFailure }
        guard response.status == 200 else {
            return .httpStatus(response.status, retryAfter: response.headers["retry-after"])
        }
        guard let snapshot = UsageSnapshot(json: response.body, fetchedAt: now) else { return .unrecognizedFormat }
        return .success(snapshot)
    }
}
