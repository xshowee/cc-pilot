// ChatGPT 档案（见 GLOSSARY.md "工具"、"档案"、ADR 0005）及其账号资料的数据模型。
// 与 Claude 一侧的 Profile 并列，不共用：Claude 的档案与 .claude.json、钥匙串绑定，ChatGPT 的档案是一个
// CODEX_HOME 目录，登录状态全部来自其中的 auth.json。界面只读这些值，不自己解析文件。
// 不含任何令牌：令牌只在发额度请求前经 ChatGPTProfileStore.usageAuthorization 取一次，用完即丢。

import Foundation

struct ChatGPTProfile: Identifiable, Equatable {
    /// 档案名；默认档案是 "default"
    let name: String
    /// 传给 CODEX_HOME 的字符串：$HOME/.codex-profiles/<名字>（绝对路径，不含 ~，结尾不带 /）。
    /// 默认档案为 nil（默认档案不设置 CODEX_HOME）。
    let codexHome: String?
    /// 档案目录：默认档案是 $HOME/.codex，其他档案同 codexHome
    let directory: String
    /// 从 auth.json 读出的账号；只在已登录 ChatGPT（可以请求额度或待续期）时有值
    let account: ChatGPTAccount?
    /// 登录状态
    let status: ChatGPTLoginStatus
    /// 与本档案登录同一账号（ChatGPTAccountKey 相同）的其他档案名，按列表顺序
    var sameAccountAs: [String] = []

    var id: String { name }
    var isDefault: Bool { name == ProfileName.defaultName }
}

/// auth.json 里 id_token 载荷的有用部分。所有字段都可能缺失。
struct ChatGPTAccount: Equatable {
    /// 邮箱（id_token 的 email）
    let email: String?
    /// 套餐（https://api.openai.com/auth 里的 chatgpt_plan_type，例如 plus、pro、team），原样保存
    let planType: String?
    /// 用户 ID（chatgpt_user_id）
    let userID: String?
    /// 工作区 ID（tokens.account_id；额度请求的 ChatGPT-Account-Id 头）
    let workspaceID: String?

    /// 账号标识；用户 ID 或工作区 ID 缺失时为 nil（不参与同一账号判断）
    var key: ChatGPTAccountKey? {
        guard let userID, let workspaceID else { return nil }
        return ChatGPTAccountKey(userID: userID, workspaceID: workspaceID)
    }
}

/// ChatGPT 账号的标识：用户 ID + 工作区 ID。同一 Team 工作区的不同用户工作区 ID 相同（issue 01 实测），
/// 所以不能只看工作区 ID。同一账号判断、额度去重、Token 用量账本的账号键都用它。
struct ChatGPTAccountKey: Hashable {
    let userID: String
    let workspaceID: String
}

/// ChatGPT 档案的登录状态（术语见 GLOSSARY.md "登录状态"）。不含任何凭据内容。
enum ChatGPTLoginStatus: Equatable {
    /// 未登录：档案里没有 auth.json
    case notLoggedIn
    /// 待续期：access token 已过期（JWT exp ≤ 现在）。在该档案中打开一次 codex 或 ChatGPT 即可恢复；
    /// cc-pilot 不续期。
    case needsRenewal
    /// 可以请求额度
    case canRequestUsage
    /// 用 API key 登录：不显示账号，不参与额度
    case apiKey
    /// 与当前 ChatGPT 版本不兼容：auth.json 打不开或读不懂
    case incompatible(ChatGPTAuthProblem)

    /// 是否可以发额度请求。只有"可以请求额度"为真。
    var allowsUsageRequest: Bool { self == .canRequestUsage }
}

enum ChatGPTAuthProblem: Equatable {
    /// auth.json 存在但打不开（权限、是目录等）
    case unreadableFile
    /// 不是 JSON、结构不认识、令牌不是可解析的 JWT，或 auth_mode 是不认识的值
    case malformed
}

enum ChatGPTUsageAuthorization {
    /// 可以请求额度；凭据只用于这一次请求
    case granted(ChatGPTUsageCredential)
    /// 不能请求，附带原因（不会是 .canRequestUsage）
    case denied(ChatGPTLoginStatus)
}

/// 一次额度请求要用的凭据。文字形式和反射都不含令牌。
struct ChatGPTUsageCredential {
    /// Authorization: Bearer 的值
    let accessToken: String
    /// ChatGPT-Account-Id 头的值（工作区 ID）
    let accountID: String
}

extension ChatGPTUsageCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ChatGPTUsageCredential(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
