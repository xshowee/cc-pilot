// 账号资料的显示文字（全部来自本地化资源；不认识的订阅等级原样显示）。

import Foundation

enum AccountText {
    /// 组织名；没有、或只是个人账号自动生成的"<邮箱>'s Organization"（与邮箱重复，没有信息量）时为 nil
    static func organization(for profile: Profile) -> String? {
        guard let account = profile.account.account, let name = account.organizationName else { return nil }
        if let email = account.email, name == "\(email)'s Organization" { return nil }
        return name
    }

    /// 订阅等级的名字，以凭据为准（见 Profile.displayTier）；不知道时为 nil
    static func tier(for profile: Profile) -> String? {
        profile.displayTier.map(tierName)
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
