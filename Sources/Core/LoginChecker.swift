// 判定档案的登录状态，并为额度请求提供凭据（ticket 11 从这里拿凭据）。
//
// 用法：
//   界面：checker.withLoginStates(store.listProfiles())  → 每个 Profile 的 login 填好，不含凭据
//   额度请求（ticket 11）：发请求前调用 usageAuthorization(for:)，只有 .granted 才发请求；
//     拿到的 UsageCredential 只在这一次请求里用，用完即丢。待续期、需重新登录等都是 .denied，
//     所以这些状态下根本拿不到令牌，也就不可能发出请求。
//
// 只读：从不写入、删除或续期任何凭据，也不写任何文件。.claude.json 没有账号资料（或读不出来）时
// 不查询钥匙串。每次调用都重新读取钥匙串，不缓存凭据。

import Foundation

enum UsageAuthorization {
    /// 可以请求额度；凭据只用于这一次请求
    case granted(UsageCredential)
    /// 不能请求，附带原因（不会是 .canRequestUsage）
    case denied(LoginStatus)
}

struct LoginChecker {
    let environment: CoreEnvironment

    init(environment: CoreEnvironment = .live) {
        self.environment = environment
    }

    /// 给每个档案填上登录信息（按顺序逐个读取钥匙串）
    func withLoginStates(_ profiles: [Profile], now: Date = Date()) -> [Profile] {
        profiles.map { profile in
            var p = profile
            p.login = loginInfo(for: profile, now: now)
            return p
        }
    }

    func loginInfo(for profile: Profile, now: Date = Date()) -> LoginInfo {
        let (status, credentials) = evaluate(profile, now: now)
        return LoginInfo(status: status, subscriptionTier: credentials.flatMap {
            SubscriptionTier.fromCredential(subscriptionType: $0.subscriptionType, rateLimitTier: $0.rateLimitTier)
        })
    }

    /// 发额度请求之前调用：重新读取凭据并判定，只有"可以请求额度"时才给出令牌
    func usageAuthorization(for profile: Profile, now: Date = Date()) -> UsageAuthorization {
        let (status, credentials) = evaluate(profile, now: now)
        // 判定为"可以请求额度"时 accessToken 一定不为空（见 LoginStatus.judge）
        guard status == .canRequestUsage, let token = credentials?.accessToken else { return .denied(status) }
        return .granted(UsageCredential(accessToken: token))
    }

    // MARK: - 内部

    /// 读取并判定；credentials 只在读到凭据时有值，调用方用完即丢
    private func evaluate(_ profile: Profile, now: Date) -> (LoginStatus, OAuthCredentials?) {
        switch profile.account {
        case .loggedOut: return (.notLoggedIn, nil)
        case .unreadable: return (.accountUnreadable, nil)
        case .loggedIn: break
        }
        switch CredentialReader(environment: environment).read(service: profile.keychainService) {
        case .failure(let failure):
            return (.incompatible(failure), nil)
        case .success(let credentials):
            return (LoginStatus.judge(credentials, now: now), credentials)
        }
    }
}
