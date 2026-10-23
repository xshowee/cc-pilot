// 订阅等级。
//
// P1 阶段不读钥匙串，.claude.json 里也没有直接叫订阅等级的字段，所以从 oauthAccount 推断：
//   organizationType           claude_pro / claude_max / claude_team / claude_enterprise
//   organizationRateLimitTier  如 default_claude_max_20x，用来补上 Max 的倍数
// 不认识的 organizationType 原样保留（.other），界面原样显示，不猜。
// ticket 10 读到凭据后，可以再用 claudeAiOauth.subscriptionType 补全或校正。

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

    /// default_claude_max_20x → 20；其他形式 → nil
    private static func maxMultiplier(_ tier: String?) -> Int? {
        let prefix = "default_claude_max_"
        guard let tier, tier.hasPrefix(prefix), tier.hasSuffix("x") else { return nil }
        let digits = tier.dropFirst(prefix.count).dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}
