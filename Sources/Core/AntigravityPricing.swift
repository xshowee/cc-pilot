// Antigravity 静态每百万 Token 美元定价目录与模型单价解析（antigravity-usage ticket 04）。
// - 随版内置 pricing-catalog.json 的完整静态定价表（零网络请求、零外部配置文件）
// - 优先精确匹配（含占位符映射），仅对已知安全变体/日期后缀做逐级剥离；未知模型或未知版本严格返回 nil，绝不伪造单价

import Foundation

/// 单个模型的每百万 Token 美元费率
struct AntigravityModelPrice: Equatable, Sendable {
    let input: Double
    let cache: Double
    let output: Double
}

/// 按展示名聚合后的单行费用状态
struct AntigravityModelCost: Equatable, Sendable {
    let name: String
    /// 组内全部正向原始条目的美元总计；任一有可见 Token 的原始条目未定价时为 nil（绝不伪造 $0）
    let costUSD: Double?
    let cacheSavingsUSD: Double?
    let isUnpriced: Bool

    var costText: String? {
        costUSD.map(AntigravityPricing.formatUSD)
    }
}

/// 一个统计分段的等效 API 美元费用、缓存读取节省与未定价模型提示
struct AntigravityCostSummary: Equatable, Sendable {
    /// 当期已定价原始模型美元总计；全部未定价时为 nil（显示 "—"）；总可见 Token 为 0 时为 0（"≈ $0.00"）
    let totalCostUSD: Double?
    let cacheSavingsUSD: Double
    /// 按可见 Token 降序排列的未定价展示名列表
    let unpricedModels: [String]
    let byModelName: [String: AntigravityModelCost]

    var totalCostText: String {
        totalCostUSD.map { "≈ \(AntigravityPricing.formatUSD($0))" } ?? "—"
    }

    var cacheSavingsText: String? {
        guard totalCostUSD != nil else { return nil }
        return AntigravityPricing.formatUSD(cacheSavingsUSD)
    }
}

enum AntigravityPricing {
    /// 与 pricing-catalog.json（catalogVersion 2026.11.13.3）同步的完整每 1M Token 美元费率表
    private static let catalog: [String: AntigravityModelPrice] = [
        // Gemini / Orchestrator
        "gemini-pro-orchestrator": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "orchestrator-carbon": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gemini-pro-orchestrator-argon": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "orchestrator-argon": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gemini-4-carbon-high": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gemini-4-carbon-medium": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gemini-4-carbon-low": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gemini-4-carbon": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gemini-4-argon-high": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gemini-4-argon-medium": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gemini-4-argon-low": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gemini-4-argon": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gemini-4-hydrogen-xhigh": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-4-hydrogen-high": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-4-hydrogen-medium": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-4-hydrogen-low": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-4-hydrogen-tiered": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-4-hydrogen": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-flash-worker-agy": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-hydrogen-xhigh": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-hydrogen-high": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-hydrogen-medium": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-hydrogen-low": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-hydrogen-tiered": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-hydrogen": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50),
        "gemini-4-helix-high": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-4-helix-medium": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-4-helix-low": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-4-helix": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-helix-high": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-helix-medium": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-helix-low": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-helix": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-3.8-flash-high": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.8-flash-medium": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.8-flash-low": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-3.8-flash-tiered": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.8-flash": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.7-flash-high": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.7-flash-medium": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.7-flash-low": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-3.7-flash-tiered": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.7-flash": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.6-flash-high": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.6-flash-medium": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.6-flash-low": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-3.6-flash": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75),
        "gemini-3.5-flash-high": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 9.00),
        "gemini-3.5-flash-medium": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 9.00),
        "gemini-3.5-flash-low": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 9.00),
        "gemini-3.5-flash-extra-low": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-3.5-flash": AntigravityModelPrice(input: 1.50, cache: 0.15, output: 9.00),
        "gemini-3.5-flash-lite": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-3.1-pro-high": AntigravityModelPrice(input: 2.00, cache: 0.20, output: 12.0),
        "gemini-3.1-pro-low": AntigravityModelPrice(input: 2.00, cache: 0.20, output: 12.0),
        "gemini-3.1-pro-low-thinking": AntigravityModelPrice(input: 2.00, cache: 0.20, output: 12.0),
        "gemini-3.1-pro-preview": AntigravityModelPrice(input: 2.00, cache: 0.20, output: 12.0),
        "gemini-3.1-pro-preview-customtools": AntigravityModelPrice(input: 2.00, cache: 0.20, output: 12.0),
        "gemini-3.1-pro": AntigravityModelPrice(input: 2.00, cache: 0.20, output: 12.0),
        "gemini-3.1-flash-lite-preview": AntigravityModelPrice(input: 0.25, cache: 0.025, output: 1.50),
        "gemini-3.1-flash-lite": AntigravityModelPrice(input: 0.25, cache: 0.025, output: 1.50),
        "gemini-for-google-3.1-flash": AntigravityModelPrice(input: 0.50, cache: 0.05, output: 3.00),
        "gemini-3.1-flash-image": AntigravityModelPrice(input: 0.50, cache: 0.05, output: 3.00),
        "gemini-3-flash-preview": AntigravityModelPrice(input: 0.50, cache: 0.05, output: 3.00),
        "gemini-3-flash": AntigravityModelPrice(input: 0.50, cache: 0.05, output: 3.00),
        "gemini-3-pro-image": AntigravityModelPrice(input: 2.00, cache: 0.20, output: 12.0),
        "gemini-2.5-pro": AntigravityModelPrice(input: 1.25, cache: 0.125, output: 10.0),
        "gemini-2.5-flash": AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50),
        "gemini-2.5-flash-lite": AntigravityModelPrice(input: 0.10, cache: 0.01, output: 0.40),

        // Claude
        "claude-fable-5-2-max": AntigravityModelPrice(input: 8.00, cache: 0.20, output: 40.0),
        "claude-fable-5-2-high": AntigravityModelPrice(input: 8.00, cache: 0.20, output: 40.0),
        "claude-fable-5-2-medium": AntigravityModelPrice(input: 8.00, cache: 0.20, output: 40.0),
        "claude-fable-5-2-low": AntigravityModelPrice(input: 8.00, cache: 0.20, output: 40.0),
        "claude-fable-5-2": AntigravityModelPrice(input: 8.00, cache: 0.20, output: 40.0),
        "claude-fable-5-1": AntigravityModelPrice(input: 10.0, cache: 0.25, output: 50.0),
        "claude-fable-5": AntigravityModelPrice(input: 10.0, cache: 1.00, output: 50.0),
        "claude-opus-5-5-max": AntigravityModelPrice(input: 4.00, cache: 0.20, output: 20.0),
        "claude-opus-5-5-high": AntigravityModelPrice(input: 4.00, cache: 0.20, output: 20.0),
        "claude-opus-5-5-medium": AntigravityModelPrice(input: 4.00, cache: 0.20, output: 20.0),
        "claude-opus-5-5-low": AntigravityModelPrice(input: 4.00, cache: 0.20, output: 20.0),
        "claude-opus-5-5": AntigravityModelPrice(input: 4.00, cache: 0.20, output: 20.0),
        "claude-opus-5": AntigravityModelPrice(input: 5.00, cache: 0.50, output: 25.0),
        "claude-opus-4-8": AntigravityModelPrice(input: 5.00, cache: 0.50, output: 25.0),
        "claude-opus-4-7": AntigravityModelPrice(input: 5.00, cache: 0.50, output: 25.0),
        "claude-opus-4-6-thinking": AntigravityModelPrice(input: 5.00, cache: 0.50, output: 25.0),
        "claude-opus-4-6": AntigravityModelPrice(input: 5.00, cache: 0.50, output: 25.0),
        "claude-opus-4-5-thinking": AntigravityModelPrice(input: 5.00, cache: 0.50, output: 25.0),
        "claude-opus-4-5": AntigravityModelPrice(input: 5.00, cache: 0.50, output: 25.0),
        "claude-sonnet-5-5-max": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "claude-sonnet-5-5-high": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "claude-sonnet-5-5-medium": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "claude-sonnet-5-5-low": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "claude-sonnet-5-5": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "claude-sonnet-5": AntigravityModelPrice(input: 2.00, cache: 0.20, output: 10.0),
        "claude-sonnet-4-6": AntigravityModelPrice(input: 3.00, cache: 0.30, output: 15.0),
        "claude-sonnet-4-5-thinking": AntigravityModelPrice(input: 3.00, cache: 0.30, output: 15.0),
        "claude-sonnet-4-5": AntigravityModelPrice(input: 3.00, cache: 0.30, output: 15.0),
        "claude-haiku-5-5": AntigravityModelPrice(input: 0.10, cache: 0.01, output: 0.50),
        "claude-haiku-4-5": AntigravityModelPrice(input: 1.00, cache: 0.10, output: 5.00),

        // OpenAI / GPT
        "gpt-6-astra": AntigravityModelPrice(input: 10.0, cache: 1.00, output: 50.0),
        "gpt-6.1-sol": AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0),
        "gpt-6.1-terra": AntigravityModelPrice(input: 1.00, cache: 0.05, output: 5.00),
        "gpt-6-sol": AntigravityModelPrice(input: 2.00, cache: 0.20, output: 10.0),
        "gpt-6-luna": AntigravityModelPrice(input: 0.10, cache: 0.01, output: 0.50),
        "gpt-5.6": AntigravityModelPrice(input: 4.00, cache: 0.40, output: 20.0),
        "gpt-5.6-sol": AntigravityModelPrice(input: 4.00, cache: 0.40, output: 20.0),
        "gpt-5.6-terra": AntigravityModelPrice(input: 2.00, cache: 0.20, output: 12.0),
        "gpt-5.6-luna": AntigravityModelPrice(input: 0.20, cache: 0.02, output: 1.20),
        "gpt-5.5": AntigravityModelPrice(input: 5.00, cache: 0.50, output: 30.0),
        "gpt-5.4": AntigravityModelPrice(input: 2.50, cache: 0.25, output: 15.0),
        "gpt-5.4-mini": AntigravityModelPrice(input: 0.75, cache: 0.075, output: 4.50),
        "gpt-5.4-nano": AntigravityModelPrice(input: 0.20, cache: 0.02, output: 1.25),
        "gpt-5.3-codex": AntigravityModelPrice(input: 1.75, cache: 0.175, output: 14.0),
        "gpt-5.2": AntigravityModelPrice(input: 1.75, cache: 0.175, output: 14.0),
        "gpt-5.1": AntigravityModelPrice(input: 1.25, cache: 0.125, output: 10.0),
        "gpt-5": AntigravityModelPrice(input: 1.25, cache: 0.125, output: 10.0),
        "gpt-5-mini": AntigravityModelPrice(input: 0.25, cache: 0.025, output: 2.00),
        "gpt-5-nano": AntigravityModelPrice(input: 0.05, cache: 0.005, output: 0.40),
        "gpt-4.1": AntigravityModelPrice(input: 2.00, cache: 0.50, output: 8.00),
        "gpt-4.1-mini": AntigravityModelPrice(input: 0.40, cache: 0.10, output: 1.60),
        "gpt-4o": AntigravityModelPrice(input: 2.50, cache: 1.25, output: 10.0),
        "gpt-4o-mini": AntigravityModelPrice(input: 0.15, cache: 0.075, output: 0.60),
        "o4-mini": AntigravityModelPrice(input: 1.10, cache: 0.275, output: 4.40),
        "o3": AntigravityModelPrice(input: 2.00, cache: 0.50, output: 8.00),
        "o3-mini": AntigravityModelPrice(input: 1.10, cache: 0.55, output: 4.40),
        "gpt-oss-120b-medium": AntigravityModelPrice(input: 0.80, cache: 0.10, output: 2.40),
    ]

    static var catalogCount: Int { catalog.count }

    private static let documentedAliases: [String: String] = [
        "orchestrator worker (hydrogen)": "gemini-flash-worker-agy",
        "orchestrator (carbon)": "orchestrator-carbon",
        "orchestrator (argon)": "orchestrator-argon",
    ]

    /// 按最具体优先顺序定义可安全剥离的后缀：先剥修饰/日期再剥档位，保证 low-thinking 优先命中 -low 价格
    private static let strippableSuffixes = [
        "-preview-customtools",
        "-extra-low",
        "-thinking",
        "-tiered",
        "-preview",
        "-latest",
        "-medium",
        "-xhigh",
        "-high",
        "-low",
        "-max",
    ]

    private static let claudeShortFamilies = ["opus ", "sonnet ", "haiku ", "fable "]

    /// 解析原始模型 ID 或占位符对应的静态单价；未知模型与未知版本返回 nil
    static func price(for rawModelID: String) -> AntigravityModelPrice? {
        var trimmed = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("session-display:") {
            trimmed = String(trimmed.dropFirst("session-display:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
        }

        let mapped = AntigravityModelResolver.staticPlaceholders[trimmed]
            ?? AntigravityModelResolver.staticPlaceholders[trimmed.uppercased()]
            ?? trimmed
        let lower = mapped.lowercased()

        if let exact = lookup(lower) {
            return exact
        }

        if let bracket = lower.firstIndex(of: "[") {
            let withoutBracket = String(lower[..<bracket])
            if let hit = resolveNormalizedSlug(withoutBracket) {
                return hit
            }
        }

        return resolveNormalizedSlug(lower)
    }

    /// 美元格式：0 为 "$0.00"，0 < x < 0.01 为 "<$0.01"，其余保留两位小数
    static func formatUSD(_ amount: Double) -> String {
        guard amount.isFinite, amount > 0 else { return "$0.00" }
        if amount < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
    }

    /// 按原始模型变体先逐条算费与缓存读取节省，再归并为按展示名分组的行费用与分段总计
    static func summarize(_ breakdown: TokenUsageBreakdown,
                          kinds: [TokenKind] = TokenKind.withoutCacheWrite) -> AntigravityCostSummary {
        let includeInput = kinds.contains(.input)
        let includeOutput = kinds.contains(.output)
        let includeCacheRead = kinds.contains(.cacheRead)

        var displayTotals: [String: Int] = [:]
        var groupPricedCost: [String: Double] = [:]
        var groupCacheSavings: [String: Double] = [:]
        var groupHasUnpriced: Set<String> = []
        var pricedRawCount = 0
        var totalPricedCost = 0.0
        var totalCacheSavings = 0.0

        for entry in breakdown.rawModels {
            let visibleTokens = entry.tokens.total(for: kinds)
            guard visibleTokens > 0 else { continue }

            let displayName = ModelDisplayName.name(for: entry.model)
            displayTotals[displayName, default: 0] += visibleTokens

            guard let price = price(for: entry.model) else {
                groupHasUnpriced.insert(displayName)
                continue
            }

            let inputCount = includeInput ? Double(max(0, entry.tokens.input)) : 0
            let cacheCount = includeCacheRead ? Double(max(0, entry.tokens.cacheRead)) : 0
            let outputCount = includeOutput ? Double(max(0, entry.tokens.output)) : 0

            let cost = (inputCount * price.input + cacheCount * price.cache + outputCount * price.output) / 1_000_000.0
            let savings = (cacheCount * max(0.0, price.input - price.cache)) / 1_000_000.0

            pricedRawCount += 1
            totalPricedCost += cost
            totalCacheSavings += savings
            groupPricedCost[displayName, default: 0] += cost
            groupCacheSavings[displayName, default: 0] += savings
        }

        guard !displayTotals.isEmpty else {
            return AntigravityCostSummary(totalCostUSD: 0, cacheSavingsUSD: 0, unpricedModels: [], byModelName: [:])
        }

        var byModelName: [String: AntigravityModelCost] = [:]
        for name in displayTotals.keys {
            if groupHasUnpriced.contains(name) {
                byModelName[name] = AntigravityModelCost(name: name, costUSD: nil, cacheSavingsUSD: nil, isUnpriced: true)
            } else {
                byModelName[name] = AntigravityModelCost(
                    name: name,
                    costUSD: groupPricedCost[name] ?? 0,
                    cacheSavingsUSD: groupCacheSavings[name] ?? 0,
                    isUnpriced: false)
            }
        }

        let unpricedModels = groupHasUnpriced.sorted {
            let lhsTokens = displayTotals[$0] ?? 0
            let rhsTokens = displayTotals[$1] ?? 0
            return (lhsTokens, $1) > (rhsTokens, $0)
        }

        let totalCostUSD: Double? = pricedRawCount > 0 ? totalPricedCost : nil
        return AntigravityCostSummary(
            totalCostUSD: totalCostUSD,
            cacheSavingsUSD: pricedRawCount > 0 ? totalCacheSavings : 0,
            unpricedModels: unpricedModels,
            byModelName: byModelName)
    }

    // MARK: - Private Resolution Helpers

    private static func resolveNormalizedSlug(_ lower: String) -> AntigravityModelPrice? {
        if let aliasTarget = documentedAliases[lower], let hit = catalog[aliasTarget] {
            return hit
        }

        if let hit = stripAndLookup(lower) {
            return hit
        }

        // 处理展示标签形式（如 "Gemini 3.8 Flash (Low)"、"Claude Opus 5.5 (High)"、"Opus 5.5"）
        if lower.contains(" ") || lower.contains("(") {
            if let slug = slugFromDisplayLabel(lower), let hit = stripAndLookup(slug) {
                return hit
            }
            if claudeShortFamilies.contains(where: { lower.hasPrefix($0) }),
               let rest = slugFromDisplayLabel("claude-" + lower),
               let hit = stripAndLookup(rest) {
                return hit
            }
        }

        return nil
    }

    private static func stripAndLookup(_ initial: String) -> AntigravityModelPrice? {
        var current = initial
        while true {
            if let hit = lookup(current) {
                return hit
            }
            if let strippedDate = stripTrailingDate(from: current) {
                current = strippedDate
                continue
            }
            if let suffix = strippableSuffixes.first(where: { current.hasSuffix($0) }) {
                current.removeLast(suffix.count)
                continue
            }
            return nil
        }
    }

    private static func lookup(_ key: String) -> AntigravityModelPrice? {
        if let exact = catalog[key] {
            return exact
        }
        if key.hasPrefix("claude-"), key.contains(".") {
            return catalog[key.replacingOccurrences(of: ".", with: "-")]
        }
        return nil
    }

    private static func stripTrailingDate(from value: String) -> String? {
        // -YYYYMMDD
        if value.count > 9 {
            let tail = value.suffix(9)
            if tail.first == "-", tail.dropFirst().allSatisfy(\.isASCIIDigit) {
                return String(value.dropLast(9))
            }
        }
        // -YYYY-MM-DD
        if value.count > 11 {
            let tail = Array(value.suffix(11))
            if tail[0] == "-", tail[5] == "-", tail[8] == "-",
               tail[1...4].allSatisfy(\.isASCIIDigit),
               tail[6...7].allSatisfy(\.isASCIIDigit),
               tail[9...10].allSatisfy(\.isASCIIDigit) {
                return String(value.dropLast(11))
            }
        }
        return nil
    }

    private static func slugFromDisplayLabel(_ lower: String) -> String? {
        var slug = ""
        var prevDash = false
        for ch in lower {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == ".") {
                slug.append(ch)
                prevDash = false
            } else if !prevDash, !slug.isEmpty {
                slug.append("-")
                prevDash = true
            }
        }
        while slug.last == "-" || slug.last == "." { slug.removeLast() }
        return slug.isEmpty ? nil : slug
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
