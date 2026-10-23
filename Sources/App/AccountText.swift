// 账号资料的显示文字（全部来自本地化资源；不认识的订阅等级原样显示）。

import Foundation

enum AccountText {
    /// "组织 · 订阅等级"，两者都没有时为 nil。订阅等级以凭据为准（见 Profile.displayTier）
    static func details(for profile: Profile) -> String? {
        guard let account = profile.account.account else { return nil }
        let parts = [account.organizationName, profile.displayTier.map(tierName)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func tierName(_ tier: SubscriptionTier) -> String {
        switch tier {
        case .pro: return String(localized: "Pro")
        case .max(let multiplier?): return String(localized: "Max \(multiplier)x")
        case .max(nil): return String(localized: "Max")
        case .team: return String(localized: "Team")
        case .enterprise: return String(localized: "Enterprise")
        case .other(let raw): return raw
        }
    }

    /// 档案名列表，用本地化的分隔符连接（英文 ", "，中文 "、"）
    static func joinedNames(_ names: [String]) -> String {
        names.joined(separator: String(localized: "list-separator", defaultValue: ", "))
    }

    static func explanation(_ error: ConfigReadError) -> String {
        switch error {
        case .unreadableFile:
            return String(localized: "This profile’s .claude.json can’t be opened.")
        case .malformed:
            return String(localized: "This profile’s .claude.json is damaged or in an unrecognized format.")
        }
    }
}
