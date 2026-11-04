// ChatGPT 账号资料的显示文字。套餐名是产品名，中英文界面都用原名；不认识的套餐原样显示。

import Foundation

enum ChatGPTAccountText {
    /// 套餐名；没有时为 nil。reported 是最近一次刷新时响应里的套餐（比 auth.json 里的新，ticket 07），优先用它。
    static func plan(for profile: ChatGPTProfile, reported: String? = nil) -> String? {
        (reported ?? profile.account?.planType).map(planName)
    }

    /// chatgpt_plan_type 原样的值 → 显示的套餐名（菜单栏只显示 ChatGPT 时的第一行也用它）
    static func planName(_ raw: String) -> String {
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
