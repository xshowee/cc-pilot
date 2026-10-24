// token-usage ticket 01：模型 ID 合并成显示名（spec 决策 13）。

import Foundation

final class ModelDisplayNameChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("模型 ID 合并成显示名，带日期后缀的也能认，不同版本分开", namesModels),
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

    static func passesUnknownThrough() throws {
        for id in ["gpt-4o", "claude-instant", "mystery"] {
            try expectEqual(ModelDisplayName.name(for: id), id, id)
        }
    }
}
