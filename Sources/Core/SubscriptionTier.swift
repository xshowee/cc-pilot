// 订阅等级。
//
// P1 阶段不读钥匙串，.claude.json 里也没有直接叫订阅等级的字段，所以从 oauthAccount 推断：
//   organizationType           claude_pro / claude_max / claude_team / claude_enterprise
//   organizationRateLimitTier  如 default_claude_max_20x，用来补上 Max 的倍数
// 不认识的 organizationType 原样保留（.other），界面原样显示，不猜。
//
// 读到钥匙串里的凭据后（ticket 10），以 claudeAiOauth.subscriptionType 为准（fromCredential），
// 认不出的取值不采用，退回上面的推断（preferring）。两处的取值都还没有在真实账号上逐一核实。

import Foundation

enum SubscriptionTier: Equatable {
    case pro
    /// Max；倍数（5、20）从限速等级推断，推断不出时为 nil
    case max(multiplier: Int?)
    case team
    case enterprise
    /// 不认识的取值，原样保留
    case other(String)

    /// 从 oauthAccount 的 organizationType（和 organizationRateLimitTier）推断。
    /// organizationType 缺失时返回 nil（不显示）。
    static func infer(organizationType: String?, rateLimitTier: String?) -> SubscriptionTier? {
        guard let type = organizationType else { return nil }
        switch type {
        case "claude_pro": return .pro
        case "claude_max": return .max(multiplier: maxMultiplier(rateLimitTier))
        case "claude_team": return .team
        case "claude_enterprise": return .enterprise
        default: return .other(type)
        }
    }

    /// 从凭据的 subscriptionType（pro / max / team / enterprise）得到；
    /// Max 的倍数取自凭据的 rateLimitTier。缺失或不认识时返回 nil。
    static func fromCredential(subscriptionType: String?, rateLimitTier: String?) -> SubscriptionTier? {
        switch subscriptionType {
        case "pro": return .pro
        case "max": return .max(multiplier: maxMultiplier(rateLimitTier))
        case "team": return .team
        case "enterprise": return .enterprise
        default: return nil
        }
    }

    /// 合并两个来源：primary 优先；primary 是倍数未知的 Max 而 fallback 知道倍数时，补上倍数。
    static func preferring(_ primary: SubscriptionTier?, over fallback: SubscriptionTier?) -> SubscriptionTier? {
        if case .max(nil)? = primary, case .max(let m?)? = fallback { return .max(multiplier: m) }
        return primary ?? fallback
    }

    /// default_claude_max_20x → 20；其他形式 → nil
    private static func maxMultiplier(_ tier: String?) -> Int? {
        let prefix = "default_claude_max_"
        guard let tier, tier.hasPrefix(prefix), tier.hasSuffix("x") else { return nil }
        let digits = tier.dropFirst(prefix.count).dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}
