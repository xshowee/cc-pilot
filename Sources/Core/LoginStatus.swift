// 档案的登录状态（spec "登录状态的判定"，术语见 GLOSSARY.md "登录状态"）。不含任何凭据内容，界面可以放心保存。

import Foundation

enum LoginStatus: Equatable {
    /// 未登录：.claude.json 里没有账号资料
    case notLoggedIn
    /// 待续期：短期凭据（accessToken）已过期，长期凭据（refreshToken）仍有效。
    /// 打开一次该档案的 claude 即可恢复；App 不为此发请求，也从不自己续期。
    case needsRenewal
    /// 需重新登录：refreshToken 为空或已过期
    case needsReLogin
    /// 不支持额度显示：scopes 里缺少 user:profile 或 user:inference
    case usageUnsupported
    /// 可以请求额度
    case canRequestUsage
    /// 与当前 Claude Code 版本不兼容：档案已登录，却读不到可用的凭据，或读取时出现授权弹窗
    case incompatible(CredentialReadFailure)
    /// .claude.json 读不出来，无从判断（不查询钥匙串）
    case accountUnreadable

    /// 是否可以发额度请求。只有"可以请求额度"为真；待续期、需重新登录等一律不发请求。
    var allowsUsageRequest: Bool { self == .canRequestUsage }

    /// 额度接口需要的两个权限
    static let requiredScopes = ["user:profile", "user:inference"]

    /// 由读到的凭据判定（已确认档案有账号资料）。按顺序：
    ///   refreshToken 为空或已过期            → 需重新登录
    ///   accessToken 为空或已过期             → 待续期
    ///   scopes 缺少 user:profile / user:inference（或没有 scopes）→ 不支持额度显示
    ///   其余                                 → 可以请求额度
    /// 过期时间缺失时按未过期处理；恰好等于 now 算已过期。
    static func judge(_ c: OAuthCredentials, now: Date) -> LoginStatus {
        func expired(_ date: Date?) -> Bool { date.map { $0 <= now } ?? false }
        if c.refreshToken == nil || expired(c.refreshTokenExpiresAt) { return .needsReLogin }
        if c.accessToken == nil || expired(c.expiresAt) { return .needsRenewal }
        let scopes = Set(c.scopes ?? [])
        if !requiredScopes.allSatisfy(scopes.contains) { return .usageUnsupported }
        return .canRequestUsage
    }
}

/// 界面显示用的登录信息（不含凭据）
struct LoginInfo: Equatable {
    let status: LoginStatus
    /// 从凭据的 subscriptionType 得到的订阅等级；没读到凭据或取值不认识时为 nil
    let subscriptionTier: SubscriptionTier?
}

extension Profile {
    /// 面板上显示的订阅等级：凭据里的 subscriptionType 优先，其次是从 .claude.json 推断的
    var displayTier: SubscriptionTier? {
        SubscriptionTier.preferring(login?.subscriptionTier, over: account.account?.tier)
    }
}
