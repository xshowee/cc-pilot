// 判定档案的登录状态，并为额度请求提供凭据（ticket 11 从这里拿凭据）。
//
// 用法：
//   界面：checker.withLoginStates(store.listProfiles())  → 每个 Profile 的 login 填好，不含凭据
//         文件变化引起的重读传 reusing: 上一次的列表，账号资料没变的档案不再查询钥匙串
//   额度请求（ticket 11）：发请求前调用 usageAuthorization(for:)，只有 .granted 才发请求；
//     拿到的 UsageCredential 只在这一次请求里用，用完即丢。待续期、需重新登录等都是 .denied，
//     所以这些状态下根本拿不到令牌，也就不可能发出请求。
//
// 只读：从不写入、删除或续期任何凭据，也不写任何文件。.claude.json 没有账号资料（或读不出来）时
// 不查询钥匙串。不缓存凭据：沿用的只是上一次的登录信息（不含凭据）。

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

    /// 给每个档案填上登录信息（按顺序逐个读取钥匙串）。
    ///
    /// reusing：上一次的结果。档案名、配置目录、账号资料都没变、而且上次已有登录信息的档案沿用上次的
    /// 登录信息，不再查询钥匙串。文件变化（FSEvents）引起的重读传上一次的列表：~/.claude.json 在
    /// Claude Code 运行时经常被改写，每次都给每个档案跑一遍 security 没有必要。钥匙串的变化（例如
    /// Claude Code 续期）无法监听，所以打开面板时不传（默认为空），全部重新读取。
    func withLoginStates(_ profiles: [Profile], reusing previous: [Profile] = [], now: Date = Date()) -> [Profile] {
        profiles.map { profile in
            var p = profile
            if let earlier = previous.first(where: { $0.name == profile.name }),
               earlier.configDir == profile.configDir, earlier.account == profile.account,
               let login = earlier.login {
                p.login = login
            } else {
                p.login = loginInfo(for: profile, now: now)
            }
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
