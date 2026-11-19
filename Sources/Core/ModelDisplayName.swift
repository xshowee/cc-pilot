// 模型 ID → 显示名（spec 决策 13）：claude-opus-5-5 → Opus 5.5。
// 日期后缀（-20250929）、-latest、推理/变体后缀（-low、-medium、-high、-xhigh、-max、-thinking、-tiered 等）、
// [1m] 之类的上下文标记都去掉，同一版本合成一个名字；不同版本分开。
// Claude：新旧两种写法都认（claude-sonnet-4-5 与 claude-3-5-sonnet）。
// ChatGPT（chatgpt-profiles ticket 09）：gpt-5.1-codex-max → GPT-5.1-Codex-Max，按 OpenAI 的写法；
//   日期后缀（-2025-08-07、-20250807）和 -latest 去掉，同一型号合成一个名字。
//   gpt-oss-* 先于 gpt-* 识别（gpt-oss-120b-medium → GPT-OSS 120B）。
// Gemini 与 Orchestrator（antigravity-usage ticket 01）：gemini-2.5-pro → Gemini 2.5 Pro、
//   gemini-4-carbon-high → Gemini 4 Carbon、gemini-for-google-3.1-flash → Gemini for Google 3.1 Flash 等。
// 认不出的（未知后缀、没有系列名或版本号等）原样返回。

import Foundation

enum ModelDisplayName {
    private static let effortSuffixes = [
        "-extra-low", "-low-thinking", "-low", "-medium", "-high", "-xhigh", "-max",
        "-thinking", "-tiered", "-latest",
    ]
    private static let geminiSuffixes = [
        "-preview-customtools", "-extra-low", "-low-thinking",
        "-low", "-medium", "-high", "-xhigh", "-max",
        "-thinking", "-tiered", "-preview", "-latest",
    ]
    private static let orchestratorNames: [String: String] = [
        "gemini-pro-orchestrator": "Orchestrator (Carbon)",
        "orchestrator-carbon": "Orchestrator (Carbon)",
        "gemini-pro-orchestrator-argon": "Orchestrator (Argon)",
        "orchestrator-argon": "Orchestrator (Argon)",
        "gemini-pro-orchestrator-neon": "Orchestrator (Neon)",
        "orchestrator-neon": "Orchestrator (Neon)",
        "gemini-flash-worker-agy": "Orchestrator Worker (Hydrogen)",
    ]
    private static let geminiRoutingAliases: [String: String] = [
        "gemini-4-argon-b": "Gemini 4 Argon",
        "gemini-4-argon-f": "Gemini 4 Argon",
        "gemini-4-argon-trial": "Gemini 4 Argon",
        "gemini-4-argon-disabled": "Gemini 4 Argon",
        "gemini-3.8-flash-n": "Gemini 3.8 Flash",
        "gemini-3.7-flash-safety-le": "Gemini 3.7 Flash",
        "gemini-3-flash-a": "Gemini 3.5 Flash",
        "gemini-3-flash-b": "Gemini 3.5 Flash",
        "gemini-3-flash-d": "Gemini 3.5 Flash",
        "gemini-3-flash-agent": "Gemini 3.5 Flash",
        "gemini-3-flash-c": "Gemini 3 Flash",
        "gemini-pro-default": "Gemini 3.1 Pro",
        "gemini-pro-agent": "Gemini 3.1 Pro",
        "gemini-pro-b": "Gemini 3.1 Pro",
    ]
    private static let geminiCodenames: Set<String> = ["hydrogen", "helix", "argon", "carbon", "neon"]
    private static let geminiTiers: Set<String> = ["pro", "flash", "argon", "carbon", "neon", "hydrogen", "helix"]
    private static let geminiVariants: Set<String> = ["lite", "image"]

    static func name(for modelID: String) -> String {
        var id = modelID
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if id.hasPrefix("gpt-oss-") { return gptOssName(id) ?? modelID }
        if id.hasPrefix("gpt-") { return gptName(id) ?? modelID }
        if id.hasPrefix("claude-") { return claudeName(id) ?? modelID }
        if id.hasPrefix("gemini-") || id.hasPrefix("orchestrator-") {
            return geminiOrOrchestratorName(id) ?? modelID
        }
        return modelID
    }

    private static func claudeName(_ id: String) -> String? {
        let stripped = stripKnownSuffixes(from: id, suffixes: effortSuffixes, stripDates: true)
        guard stripped.hasPrefix("claude-") else { return nil }
        var family: String?
        var version: [String] = []
        for part in stripped.dropFirst("claude-".count).split(separator: "-") {
            if part.allSatisfy(\.isASCIIDigit) {
                version.append(String(part))
            } else if family == nil, part.allSatisfy(\.isLetter) {
                family = capitalized(part)
            } else {
                return nil
            }
        }
        guard let family, !version.isEmpty else { return nil }
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
        return (["GPT", version] + parts.dropFirst().map { capitalized($0) })
            .joined(separator: "-")
    }

    /// gpt-oss-<size>：去掉已知后缀后将模型族与大小写为大写（如 gpt-oss-120b-medium → GPT-OSS 120B）
    private static func gptOssName(_ id: String) -> String? {
        let stripped = stripKnownSuffixes(from: id, suffixes: effortSuffixes)
        guard stripped.hasPrefix("gpt-oss-") else { return nil }
        let size = String(stripped.dropFirst("gpt-oss-".count))
        guard !size.isEmpty, !size.contains("-"),
              size.first?.isASCIIDigit == true,
              size.allSatisfy({ $0.isASCIIDigit || $0.isLetter || $0 == "." }) else { return nil }
        return "GPT-OSS \(size.uppercased())"
    }

    private static func geminiOrOrchestratorName(_ id: String) -> String? {
        let stripped = stripKnownSuffixes(from: id, suffixes: geminiSuffixes, stripDates: true)
        if let mapped = orchestratorNames[stripped] { return mapped }
        if let mapped = geminiRoutingAliases[stripped] { return mapped }
        guard stripped.hasPrefix("gemini-") else { return nil }
        let parts = stripped.dropFirst("gemini-".count)
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        if parts.count >= 4, parts[0] == "for", parts[1] == "google",
           let formatted = formatGeminiVersionAndTier(parts.dropFirst(2)) {
            return "Gemini for Google \(formatted)"
        }
        if let formatted = formatGeminiVersionAndTier(parts[...]) {
            return "Gemini \(formatted)"
        }
        if parts.count == 1, geminiCodenames.contains(parts[0]) {
            return "Gemini \(capitalized(parts[0]))"
        }
        return nil
    }

    private static func formatGeminiVersionAndTier(_ parts: ArraySlice<String>) -> String? {
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let version = parts[parts.startIndex]
        let tier = parts[parts.startIndex + 1]
        guard isVersion(version), geminiTiers.contains(tier) else { return nil }
        if parts.count == 3 {
            let variant = parts[parts.startIndex + 2]
            guard geminiVariants.contains(variant) else { return nil }
            return "\(version) \(capitalized(tier)) \(capitalized(variant))"
        }
        return "\(version) \(capitalized(tier))"
    }

    private static func isVersion(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }
    }

    private static func capitalized<S: StringProtocol>(_ value: S) -> String {
        value.prefix(1).uppercased() + value.dropFirst()
    }

    private static func stripKnownSuffixes(from id: String, suffixes: [String],
                                           stripDates: Bool = false) -> String {
        var result = id
        while true {
            if let suffix = suffixes.first(where: { result.hasSuffix($0) }) {
                result.removeLast(suffix.count)
                continue
            }
            if stripDates, result.count > 9 {
                let tail = result.suffix(9)
                if tail.first == "-", tail.dropFirst().allSatisfy(\.isASCIIDigit) {
                    result.removeLast(9)
                    continue
                }
            }
            return result
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
