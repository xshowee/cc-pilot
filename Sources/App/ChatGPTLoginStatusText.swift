// ChatGPT 档案登录状态的显示文字（全部来自本地化资源）。

import Foundation

enum ChatGPTLoginStatusText {
    /// 状态名；不需要单独一行状态名时为 nil（未登录、可以请求额度由标题说明；API key 只显示提示）
    static func title(_ status: ChatGPTLoginStatus) -> String? {
        switch status {
        case .notLoggedIn, .canRequestUsage, .apiKey: return nil
        case .needsRenewal: return String(localized: "Needs renewal")
        case .incompatible: return String(localized: "Incompatible with the current ChatGPT version")
        }
    }

    /// 告诉用户怎么办的提示；不需要时为 nil
    static func hint(_ status: ChatGPTLoginStatus) -> String? {
        switch status {
        case .notLoggedIn, .canRequestUsage: return nil
        case .needsRenewal:
            return String(localized: "Open codex or ChatGPT in this profile once to restore it.")
        case .apiKey:
            return String(localized: "Usage isn’t shown for API key sign-ins.")
        case .incompatible(.unreadableFile):
            return String(localized: "This profile’s auth.json can’t be opened.") + " "
                + String(localized: "Please update cc-pilot.")
        case .incompatible(.malformed):
            return String(localized: "This profile’s auth.json is in an unrecognized format.") + " "
                + String(localized: "Please update cc-pilot.")
        }
    }
}
