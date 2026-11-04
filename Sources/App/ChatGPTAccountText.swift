// ChatGPT 账号资料的显示文字。套餐名是产品名，中英文界面都用原名；不认识的套餐原样显示。

import Foundation

enum ChatGPTAccountText {
    /// 套餐名；没有时为 nil
    static func plan(for profile: ChatGPTProfile) -> String? {
        guard let raw = profile.account?.planType else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        default: return raw
        }
    }
}
