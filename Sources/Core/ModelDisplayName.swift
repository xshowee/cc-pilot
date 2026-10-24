// 模型 ID → 显示名（spec 决策 13）：claude-opus-5-5 → Opus 5.5。
// 日期后缀（-20250929）、-latest、[1m] 之类的上下文标记都去掉，同一版本合成一个名字；不同版本分开。
// 新旧两种写法都认：claude-<系列>-<版本…>（claude-sonnet-4-5）和 claude-<版本…>-<系列>（claude-3-5-sonnet）。
// 认不出的（不是 claude- 开头、没有系列名或没有版本号）原样返回。

import Foundation

enum ModelDisplayName {
    static func name(for modelID: String) -> String {
        var id = modelID
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
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
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
