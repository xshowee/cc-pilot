// 模型 ID → 显示名（spec 决策 13）：claude-opus-5-5 → Opus 5.5。
// 日期后缀（-20250929）、-latest、[1m] 之类的上下文标记都去掉，同一版本合成一个名字；不同版本分开。
// 新旧两种写法都认：claude-<系列>-<版本…>（claude-sonnet-4-5）和 claude-<版本…>-<系列>（claude-3-5-sonnet）。
// ChatGPT（chatgpt-profiles ticket 09）：gpt-5.1-codex-max → GPT-5.1-Codex-Max，按 OpenAI 的写法；
// 日期后缀（-2025-08-07、-20250807）和 -latest 去掉，同一型号合成一个名字。
// 认不出的（不是 claude- / gpt- 开头、没有系列名或没有版本号）原样返回。

import Foundation

enum ModelDisplayName {
    static func name(for modelID: String) -> String {
        var id = modelID
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if id.hasPrefix("gpt-") { return gptName(id) ?? modelID }
        guard id.hasPrefix("claude-") else { return modelID }
        var family: String?
        var version: [String] = []
        for part in id.dropFirst("claude-".count).split(separator: "-") {
            if part == "latest" || (part.count == 8 && part.allSatisfy(\.isASCIIDigit)) { continue }
            if part.allSatisfy(\.isASCIIDigit) {
                version.append(String(part))
            } else if family == nil, part.allSatisfy(\.isLetter) {
                family = part.prefix(1).uppercased() + part.dropFirst()
            } else {
                return modelID
            }
        }
        guard let family, !version.isEmpty else { return modelID }
        return family + " " + version.joined(separator: ".")
    }

    /// gpt-<版本>[-<变体>…]：版本原样（5.1、4o），变体首字母大写；版本不以数字开头时认不出
    private static func gptName(_ id: String) -> String? {
        var parts = id.dropFirst("gpt-".count).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "latest" { parts.removeLast() }
        if parts.count >= 3, parts.suffix(3).map(\.count) == [4, 2, 2],
           parts.suffix(3).allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }) {
            parts.removeLast(3)
        } else if let last = parts.last, last.count == 8, last.allSatisfy(\.isASCIIDigit) {
            parts.removeLast()
        }
        guard let version = parts.first, version.first?.isASCIIDigit == true,
              parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return (["GPT", version] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() })
            .joined(separator: "-")
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
