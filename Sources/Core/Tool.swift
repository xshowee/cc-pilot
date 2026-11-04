// 工具（见 GLOSSARY.md "工具"）：档案所属的一方。两个工具的档案、当前档案各自独立。
// Claude Code 一侧沿用原有的 Profile / ProfileStore 等类型；ChatGPT 一侧是 ChatGPTProfile / ChatGPTProfileStore。

import Foundation

enum Tool: String, CaseIterable, Sendable {
    case claudeCode
    case chatgpt

    /// 产品名（中英文界面都用原名）
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .chatgpt: return "ChatGPT"
        }
    }
}
