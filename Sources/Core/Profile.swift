// 档案（见 GLOSSARY.md）及其账号资料的数据模型。界面只读这些值，不自己解析文件。

import Foundation

struct Profile: Identifiable, Equatable {
    /// 档案名；默认档案是 "default"
    let name: String
    /// 传给 CLAUDE_CONFIG_DIR 的字符串：$HOME/.claude-profiles/<名字>（绝对路径，不含 ~，结尾不带 /）。
    /// 默认档案为 nil（默认档案不设置 CLAUDE_CONFIG_DIR）。钥匙串 service 名就由这个字符串算出。
    let configDir: String?
    /// 这个档案的 .claude.json：默认档案在 $HOME/.claude.json，其他档案在 <configDir>/.claude.json
    let claudeJSON: URL
    /// 从 .claude.json 读出的账号状态
    let account: AccountState
    /// 与本档案登录同一账号（accountUuid 相同）的其他档案名，按列表顺序；未登录时为空
    var sameAccountAs: [String] = []
    /// 登录状态（读取钥匙串后才有，见 LoginChecker.withLoginStates；listProfiles 不填）
    var login: LoginInfo? = nil

    var id: String { name }
    var isDefault: Bool { name == ProfileName.defaultName }
}

/// 档案的账号状态（只看 .claude.json；读取凭据后的细分状态见 Profile.login）
enum AccountState: Equatable {
    /// .claude.json 不存在，或其中没有账号资料（oauthAccount）
    case loggedOut
    /// 已登录
    case loggedIn(Account)
    /// .claude.json 存在但读不出来：不是 JSON、结构不认识、或没有读取权限
    case unreadable(ConfigReadError)

    var account: Account? {
        if case .loggedIn(let account) = self { return account }
        return nil
    }
}

enum ConfigReadError: Equatable {
    /// 文件存在但无法读取（权限、是目录等）
    case unreadableFile
    /// 不是合法 JSON，或顶层 / oauthAccount 的类型不对
    case malformed
}

/// .claude.json 里 oauthAccount 的有用部分。所有字段都可能缺失或为 null。
struct Account: Equatable {
    /// 账号唯一标识，用来判断两个档案是否是同一账号
    let accountUuid: String?
    let email: String?
    let organizationName: String?
    /// 订阅等级（由 organizationType 等字段推断，见 SubscriptionTier）
    let tier: SubscriptionTier?
}
