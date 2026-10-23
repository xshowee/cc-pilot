// 登录状态的显示文字（全部来自本地化资源）。

import Foundation

enum LoginStatusText {
    /// 状态名；未登录、.claude.json 读不出时返回 nil（ProfileRow 的标题已经说明了）
    static func title(_ status: LoginStatus) -> String? {
        switch status {
        case .notLoggedIn, .accountUnreadable: return nil
        case .canRequestUsage: return String(localized: "Signed in")
        case .needsRenewal: return String(localized: "Needs renewal")
        case .needsReLogin: return String(localized: "Needs to sign in again")
        case .usageUnsupported: return String(localized: "Usage not supported")
        case .incompatible: return String(localized: "Incompatible with the current Claude Code version")
        }
    }

    /// 告诉用户怎么办的提示；不需要时为 nil
    static func hint(_ status: LoginStatus) -> String? {
        switch status {
        case .notLoggedIn, .accountUnreadable, .canRequestUsage: return nil
        case .needsRenewal:
            return String(localized: "Open claude in this profile once to restore it.")
        case .needsReLogin:
            return String(localized: "Run /login in this profile’s claude to sign in again.")
        case .usageUnsupported:
            return String(localized: "This sign-in method doesn’t support usage display.")
        case .incompatible(let reason):
            return reasonText(reason) + " "
                + String(localized: "Please update cc-pilot. If macOS asks for keychain access, don’t allow it.")
        }
    }

    private static func reasonText(_ reason: CredentialReadFailure) -> String {
        switch reason {
        case .itemNotFound:
            return String(localized: "This profile is signed in, but its credentials weren’t found in the keychain.")
        case .emptyItem:
            return String(localized: "This profile is signed in, but its keychain item is empty.")
        case .unrecognizedFormat:
            return String(localized: "The credentials in the keychain are in an unrecognized format.")
        case .readFailed(let code?):
            return String(localized: "Reading the keychain failed (security exit code \(Int(code))).")
        case .readFailed(nil):
            return String(localized: "The security tool couldn’t be started.")
        case .timedOut:
            return String(localized: "Reading the keychain didn’t finish in time; a keychain access prompt may have appeared.")
        }
    }
}
