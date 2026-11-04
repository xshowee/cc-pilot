// token-usage ticket 01：模型 ID 合并成显示名（spec 决策 13）。

import Foundation

final class ModelDisplayNameChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("模型 ID 合并成显示名，带日期后缀的也能认，不同版本分开", namesModels),
            Check("ChatGPT 的模型 ID 也合并成显示名（chatgpt-profiles ticket 09）", namesChatGPTModels),
            Check("认不出的模型 ID 原样显示", passesUnknownThrough),
        ]
    }

    static func namesModels() throws {
        let cases: [(String, String)] = [
            ("claude-opus-5-5", "Opus 5.5"),
            ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
            ("claude-sonnet-4-5", "Sonnet 4.5"),
            ("claude-opus-4-20250514", "Opus 4"),
            ("claude-opus-4-1-20250805", "Opus 4.1"),
            ("claude-haiku-4-5-20251001", "Haiku 4.5"),
            ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
            ("claude-3-7-sonnet-latest", "Sonnet 3.7"),
            ("claude-3-haiku-20240307", "Haiku 3"),
            ("claude-opus-4-6[1m]", "Opus 4.6"),
        ]
        for (id, name) in cases {
            try expectEqual(ModelDisplayName.name(for: id), name, id)
        }
    }

    static func namesChatGPTModels() throws {
        let cases: [(String, String)] = [
            ("gpt-5.3-codex", "GPT-5.3-Codex"),
            ("gpt-5.1-codex-max", "GPT-5.1-Codex-Max"),
            ("gpt-5-codex", "GPT-5-Codex"),
            ("gpt-5", "GPT-5"),
            ("gpt-5-2025-08-07", "GPT-5"),
            ("gpt-5.1-codex-mini-latest", "GPT-5.1-Codex-Mini"),
            ("gpt-4o", "GPT-4o"),
        ]
        for (id, name) in cases {
            try expectEqual(ModelDisplayName.name(for: id), name, id)
        }
    }

    static func passesUnknownThrough() throws {
        for id in ["o3", "gpt-", "gpt-codex", "claude-instant", "mystery", ""] {
            try expectEqual(ModelDisplayName.name(for: id), id, id)
        }
    }
}
