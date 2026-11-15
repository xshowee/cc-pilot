// antigravity-usage ticket 04：静态定价目录解析、USD 格式化、动态算费与未定价模型保护。
// 覆盖：
// - 静态定价表完整嵌入、占位符映射、安全后缀剥离与未知模型拒绝（返回 nil）
// - 多模型加权美元成本与缓存读取节省、同名不同档位变体先算费再合并
// - 全未定价（nil / "—"）与部分未定价诚实处理（不伪造 $0）
// - 经真实 SQLite TokenLedger（保持 user_version = 5）验证 5h / 周 / 累计（含 rollUp 后 daily 行）一致性

import Foundation

final class AntigravityPricingChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("静态定价目录：覆盖主流模型与占位符映射，安全变体后缀匹配，未知模型返回 nil", catalogResolution),
            Check("USD 格式化：0 写 $0.00，小于 $0.01 写 <$0.01，其余保留两位小数", usdFormatting),
            Check("动态算费与同名变体合并：先按原始模型算费与缓存节省，再按展示名合并", weightedCostAndVariantMerging),
            Check("未定价模型诚实处理：全未定价总额为 nil，部分未定价仅计已定价且不伪造 $0", unpricedAndPartialHandling),
            Check("TokenFigure 开关：默认不附带费用，开启 includeCost 后填充总额、节省与模型行", tokenFigureIntegration),
            Check("端到端账本一致性：5h / 周 / 累计（含 rollUp 后的 daily 历史汇总）与清空累计联动，schema 保持 v5", endToEndLedgerAndRollupConsistency),
        ]
    }

    static func expectClose(_ actual: Double?, _ expected: Double, _ message: String = "",
                            tolerance: Double = 1e-9, file: StaticString = #fileID, line: UInt = #line) throws {
        let value = try unwrap(actual, message.isEmpty ? "期望非 nil 金额" : message, file: file, line: line)
        if abs(value - expected) > tolerance {
            throw CheckFailure(description: "\(file):\(line): \(message) 得到 \(value)，期望 \(expected)")
        }
    }

    static func catalogResolution() throws {
        // 1. 静态定价目录完整收录 126 个条目，且 58 个静态占位符均可解析到单价
        try expectEqual(AntigravityPricing.catalogCount, 126, "应完整嵌入 pricing-catalog.json 的 126 条定价")
        for (placeholder, modelID) in AntigravityModelResolver.staticPlaceholders {
            try expect(AntigravityPricing.price(for: placeholder) != nil,
                       "占位符 \(placeholder) -> \(modelID) 应可解析定价")
        }

        // 2. 同展示名不同档位必须精确区分单价
        try expectEqual(AntigravityPricing.price(for: "gemini-3.8-flash-high"),
                        AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75))
        try expectEqual(AntigravityPricing.price(for: "gemini-3.8-flash-low"),
                        AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50))
        try expectEqual(AntigravityPricing.price(for: "MODEL_PLACEHOLDER_M320"),
                        AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50))
        try expectEqual(AntigravityPricing.price(for: "MODEL_PLACEHOLDER_M318"),
                        AntigravityModelPrice(input: 0.75, cache: 0.075, output: 3.75))

        // 3. Claude / GPT / Orchestrator 精确匹配与大小写无关
        try expectEqual(AntigravityPricing.price(for: "Claude-Opus-5-5-High"),
                        AntigravityModelPrice(input: 4.00, cache: 0.20, output: 20.0))
        try expectEqual(AntigravityPricing.price(for: "claude-opus-4-6-thinking"),
                        AntigravityModelPrice(input: 5.00, cache: 0.50, output: 25.0))
        try expectEqual(AntigravityPricing.price(for: "gpt-5.4"),
                        AntigravityModelPrice(input: 2.50, cache: 0.25, output: 15.0))
        try expectEqual(AntigravityPricing.price(for: "gpt-oss-120b-medium"),
                        AntigravityModelPrice(input: 0.80, cache: 0.10, output: 2.40))
        try expectEqual(AntigravityPricing.price(for: "gemini-pro-orchestrator"),
                        AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0))
        try expectEqual(AntigravityPricing.price(for: "orchestrator-argon"),
                        AntigravityModelPrice(input: 2.00, cache: 0.10, output: 10.0))
        try expectEqual(AntigravityPricing.price(for: "gemini-flash-worker-agy"),
                        AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50))

        // 4. 安全后缀剥离：先剥日期/修饰后缀再匹配，保留更具体的低档位单价
        try expectEqual(AntigravityPricing.price(for: "gemini-3.8-flash-low-20260501"),
                        AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50))
        try expectEqual(AntigravityPricing.price(for: "gemini-3.8-flash-low-thinking"),
                        AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50))
        try expectEqual(AntigravityPricing.price(for: "claude-sonnet-4-5-20250929"),
                        AntigravityModelPrice(input: 3.00, cache: 0.30, output: 15.0))
        try expectEqual(AntigravityPricing.price(for: "claude-opus-4-6[1m]"),
                        AntigravityModelPrice(input: 5.00, cache: 0.50, output: 25.0))
        try expectEqual(AntigravityPricing.price(for: "gemini-3.1-pro-high-preview-customtools"),
                        AntigravityModelPrice(input: 2.00, cache: 0.20, output: 12.0))
        try expectEqual(AntigravityPricing.price(for: "gpt-5-2025-08-07"),
                        AntigravityModelPrice(input: 1.25, cache: 0.125, output: 10.0))
        try expectEqual(AntigravityPricing.price(for: "Gemini 3.8 Flash (Low)"),
                        AntigravityModelPrice(input: 0.30, cache: 0.03, output: 2.50))
        try expectEqual(AntigravityPricing.price(for: "Orchestrator Worker (Hydrogen)"),
                        AntigravityModelPrice(input: 1.50, cache: 0.15, output: 7.50))

        // 5. 未知模型与未知版本严禁兜底，必须返回 nil
        for unknown in ["", "   ", "unknown", "MODEL_UNKNOWN", "MODEL_PLACEHOLDER_M999",
                        "unknown-model-v9", "gemini-9.9-ultra", "gemini-9.9-ultra-high",
                        "gemini-3.1-pro-ultra-v2", "claude-opus-5-5-fast", "claude-9-sonnet",
                        "gpt-5.1-codex", "gpt-99", "o1"] {
            try expectEqual(AntigravityPricing.price(for: unknown), nil, "未知模型 \(unknown) 应返回 nil")
        }
    }

    static func usdFormatting() throws {
        try expectEqual(AntigravityPricing.formatUSD(0), "$0.00")
        try expectEqual(AntigravityPricing.formatUSD(-0.5), "$0.00")
        try expectEqual(AntigravityPricing.formatUSD(.nan), "$0.00")
        try expectEqual(AntigravityPricing.formatUSD(.infinity), "$0.00")
        try expectEqual(AntigravityPricing.formatUSD(0.0001), "<$0.01")
        try expectEqual(AntigravityPricing.formatUSD(0.0099), "<$0.01")
        try expectEqual(AntigravityPricing.formatUSD(0.01), "$0.01")
        try expectEqual(AntigravityPricing.formatUSD(1.234), "$1.23")
        try expectEqual(AntigravityPricing.formatUSD(12.346), "$12.35")
    }

    static func counts(_ input: Int, _ output: Int, _ cacheWrite: Int = 0, _ cacheRead: Int = 0) -> TokenCounts {
        TokenCounts(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
    }

    static func weightedCostAndVariantMerging() throws {
        // 1) 同展示名不同价格变体：
        //    gemini-3.8-flash-high: 1M input ($0.75) + 2M cacheRead ($0.075*2=$0.15) + 1M output ($3.75) = $4.65
        //      cacheSavings = 2M * (0.75 - 0.075) = $1.35
        //    gemini-3.8-flash-low:  2M input ($0.30*2=$0.60) + 1M cacheRead ($0.03) + 1M output ($2.50) = $3.13
        //      cacheSavings = 1M * (0.30 - 0.03) = $0.27
        //    合并后 "Gemini 3.8 Flash": cost = $7.78, savings = $1.62
        // 2) 多模型叠加：
        //    claude-opus-5-5-high: 500K input ($4*0.5=$2.00) + 1M cacheRead ($0.20) + 200K output ($20*0.2=$4.00) = $6.20
        //      cacheSavings = 1M * (4.00 - 0.20) = $3.80
        //    总计 = $7.78 + $6.20 = $13.98, 总缓存节省 = $1.62 + $3.80 = $5.42
        let breakdown = TokenUsageBreakdown([
            (model: "gemini-3.8-flash-high", tokens: counts(1_000_000, 1_000_000, 0, 2_000_000)),
            (model: "gemini-3.8-flash-low", tokens: counts(2_000_000, 1_000_000, 0, 1_000_000)),
            (model: "claude-opus-5-5-high", tokens: counts(500_000, 200_000, 0, 1_000_000)),
        ])

        try expectEqual(breakdown.byModel.map(\.model), ["Gemini 3.8 Flash", "Opus 5.5"])
        try expectEqual(breakdown.rawModels.map(\.model),
                        ["gemini-3.8-flash-high", "gemini-3.8-flash-low", "claude-opus-5-5-high"])

        let summary = AntigravityPricing.summarize(breakdown, kinds: TokenKind.withoutCacheWrite)
        try expectClose(summary.totalCostUSD, 13.98, "总费用")
        try expectEqual(summary.totalCostText, "≈ $13.98")
        try expectClose(summary.cacheSavingsUSD, 5.42, "总缓存节省")
        try expectEqual(summary.cacheSavingsText, "$5.42")
        try expectEqual(summary.unpricedModels, [])

        let flashCost = try unwrap(summary.byModelName["Gemini 3.8 Flash"])
        try expectClose(flashCost.costUSD, 7.78, "Gemini 3.8 Flash 变体先算费再合并")
        try expectClose(flashCost.cacheSavingsUSD, 1.62)
        try expectEqual(flashCost.costText, "$7.78")
        try expectEqual(flashCost.isUnpriced, false)

        let opusCost = try unwrap(summary.byModelName["Opus 5.5"])
        try expectClose(opusCost.costUSD, 6.20)
        try expectEqual(opusCost.costText, "$6.20")
        try expectEqual(opusCost.isUnpriced, false)
    }

    static func unpricedAndPartialHandling() throws {
        // 1) 空分段（总可见 token == 0，含仅 cacheWrite 的条目）
        let emptySummary = AntigravityPricing.summarize(.empty, kinds: TokenKind.withoutCacheWrite)
        try expectClose(emptySummary.totalCostUSD, 0)
        try expectEqual(emptySummary.totalCostText, "≈ $0.00")
        try expectClose(emptySummary.cacheSavingsUSD, 0)
        try expectEqual(emptySummary.cacheSavingsText, "$0.00")
        try expectEqual(emptySummary.unpricedModels, [])

        let cacheWriteOnly = TokenUsageBreakdown([
            (model: "unknown-model-v9", tokens: counts(0, 0, 50_000, 0)),
        ])
        let invisibleSummary = AntigravityPricing.summarize(cacheWriteOnly, kinds: TokenKind.withoutCacheWrite)
        try expectClose(invisibleSummary.totalCostUSD, 0)
        try expectEqual(invisibleSummary.unpricedModels, [], "可见 token 为 0 时不计为未定价模型")

        // 2) 全未定价模型：总额必须为 nil（显示 "—"），绝不伪造 $0.00
        let allUnpriced = TokenUsageBreakdown([
            (model: "gemini-9.9-ultra", tokens: counts(1_000_000, 500_000, 0, 200_000)),
            (model: "unknown-model-v9", tokens: counts(100_000, 50_000, 0, 0)),
        ])
        let allUnpricedSummary = AntigravityPricing.summarize(allUnpriced, kinds: TokenKind.withoutCacheWrite)
        try expectEqual(allUnpricedSummary.totalCostUSD, nil)
        try expectEqual(allUnpricedSummary.totalCostText, "—")
        try expectEqual(allUnpricedSummary.cacheSavingsText, nil)
        try expectEqual(allUnpricedSummary.unpricedModels, ["gemini-9.9-ultra", "unknown-model-v9"])
        try expectEqual(allUnpricedSummary.byModelName["gemini-9.9-ultra"]?.isUnpriced, true)
        try expectEqual(allUnpricedSummary.byModelName["gemini-9.9-ultra"]?.costUSD, nil)
        try expectEqual(allUnpricedSummary.byModelName["gemini-9.9-ultra"]?.costText, nil)

        // 3) 部分已定价 + 同展示组内混合（gpt-oss-120b-medium 已定价 vs gpt-oss-120b-high 未定价）
        //    gemini-3.8-flash-low: 1M input = $0.30
        //    gpt-oss-120b-medium: 1M input = $0.80
        //    gpt-oss-120b-high: 500K input -> 未定价（同属 GPT-OSS 120B 组）
        //    gemini-9.9-ultra: 2M input -> 未定价
        //    周期总计仅累加已定价原始模型 ($0.30 + $0.80 = $1.10)，但 GPT-OSS 120B 与 gemini-9.9-ultra 行均标记 isUnpriced = true
        let mixed = TokenUsageBreakdown([
            (model: "gemini-3.8-flash-low", tokens: counts(1_000_000, 0)),
            (model: "gpt-oss-120b-medium", tokens: counts(1_000_000, 0)),
            (model: "gpt-oss-120b-high", tokens: counts(500_000, 0)),
            (model: "gemini-9.9-ultra", tokens: counts(2_000_000, 0)),
        ])
        let mixedSummary = AntigravityPricing.summarize(mixed, kinds: TokenKind.withoutCacheWrite)
        try expectClose(mixedSummary.totalCostUSD, 1.10)
        try expectEqual(mixedSummary.totalCostText, "≈ $1.10")
        try expectEqual(mixedSummary.unpricedModels, ["gemini-9.9-ultra", "GPT-OSS 120B"])
        try expectEqual(mixedSummary.byModelName["Gemini 3.8 Flash"]?.isUnpriced, false)
        try expectEqual(mixedSummary.byModelName["Gemini 3.8 Flash"]?.costText, "$0.30")
        try expectEqual(mixedSummary.byModelName["GPT-OSS 120B"]?.isUnpriced, true)
        try expectEqual(mixedSummary.byModelName["GPT-OSS 120B"]?.costUSD, nil)
        try expectEqual(mixedSummary.byModelName["gemini-9.9-ultra"]?.isUnpriced, true)
    }

    static func tokenFigureIntegration() throws {
        let now = fixedNow
        let fiveHourBreakdown = TokenUsageBreakdown([
            (model: "gemini-3.8-flash-low", tokens: counts(10_000, 1_000, 0, 100_000)),
            (model: "gemini-9.9-ultra", tokens: counts(5_000, 500, 0, 0)),
        ])
        let usage = AccountTokenUsage(
            fiveHour: TokenUsageWindow(start: now.addingTimeInterval(-3600), end: now, usage: fiveHourBreakdown),
            sevenDay: TokenUsageWindow(start: now.addingTimeInterval(-86400), end: now, usage: .empty),
            cumulative: TokenUsageCumulative(origin: now.addingTimeInterval(-86400), usage: .empty),
            hourly: [],
            daily: [])

        // 默认 includeCost = false（Claude / ChatGPT 不展示任何费用）
        let plain = TokenFigure(usage, period: .fiveHour, kinds: TokenKind.withoutCacheWrite)
        try expectEqual(plain.cost, nil)
        try expectEqual(plain.models.map(\.costText), [nil, nil])
        try expectEqual(plain.models.map(\.isUnpriced), [false, false])

        // Antigravity 开启 includeCost = true：
        // gemini-3.8-flash-low: (10000*0.30 + 100000*0.03 + 1000*2.50) / 1e6 = (3000 + 3000 + 2500) / 1e6 = $0.0085 (<$0.01)
        // cacheSavings = 100000 * (0.30 - 0.03) / 1e6 = $0.027 -> $0.03
        let withCost = TokenFigure(usage, period: .fiveHour, kinds: TokenKind.withoutCacheWrite, includeCost: true)
        let cost = try unwrap(withCost.cost)
        try expectClose(cost.totalCostUSD, 0.0085)
        try expectEqual(cost.totalCostText, "≈ <$0.01")
        try expectClose(cost.cacheSavingsUSD, 0.027)
        try expectEqual(cost.cacheSavingsText, "$0.03")
        try expectEqual(cost.unpricedModels, ["gemini-9.9-ultra"])
        try expectEqual(withCost.models, [
            TokenFigure.ModelRow(name: "Gemini 3.8 Flash", value: "111.0K", share: "95%",
                                 costText: "<$0.01", isUnpriced: false),
            TokenFigure.ModelRow(name: "gemini-9.9-ultra", value: "5.5K", share: "5%",
                                 costText: nil, isUnpriced: true),
        ])
    }

    static func endToEndLedgerAndRollupConsistency() throws {
        let home = try TempHome()
        defer { home.remove() }
        let ledger = try TokenLedger(at: home.url.appendingPathComponent("ledger.sqlite"))

        func schemaVersion() throws -> Int {
            let st = try ledger.db.prepare("PRAGMA user_version")
            _ = try st.step()
            return st.int(0)
        }
        try expectEqual(try schemaVersion(), 5)

        let cal = TokenLedgerRollupChecks.calendar
        let listenerStartedAt = try unwrap(AntigravityModelResolver.parseISO8601("2026-09-01T00:00:00Z"))
        let now = try unwrap(AntigravityModelResolver.parseISO8601("2026-11-15T12:00:00Z"))

        func step(_ session: String, _ idx: Int, _ iso: String, _ model: String,
                  input: Int, output: Int = 0, cacheRead: Int = 0) throws -> AntigravityTrajectoryStep {
            let at = try unwrap(AntigravityModelResolver.parseISO8601(iso))
            return AntigravityTrajectoryStep(
                messageID: "antigravity:\(session):\(idx)",
                sessionID: session,
                stepIndex: idx,
                completedAt: at,
                createdAt: at,
                finishedAt: at,
                model: model,
                tokens: TokenCounts(input: input, output: output, cacheWrite: 0, cacheRead: cacheRead),
                isCompactionStep: false,
                timeToFirstTokenSec: nil)
        }

        // 1) 61 天前的旧会话：将在 rollUp(retentionDays: 30) 后合并进 daily（保留原始变体 model 列）
        let oldBatch = AntigravityExtractedBatch(
            sessionID: "s-old", parentSessionID: nil, rootSessionID: nil, childCascadeIDs: [],
            steps: [
                try step("s-old", 0, "2026-09-15T10:00:00Z", "gemini-3.8-flash-low",
                         input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000), // $2.83, saved $0.27
                try step("s-old", 1, "2026-09-15T10:05:00Z", "gemini-3.8-flash-high",
                         input: 1_000_000),                                           // $0.75
            ])
        // 2) 周窗口内（5h 窗口外）
        let weekBatch = AntigravityExtractedBatch(
            sessionID: "s-week", parentSessionID: nil, rootSessionID: nil, childCascadeIDs: [],
            steps: [
                try step("s-week", 0, "2026-11-13T10:00:00Z", "claude-opus-5-5-high",
                         input: 500_000, output: 200_000, cacheRead: 1_000_000),      // $6.20, saved $3.80
            ])
        // 3) 5 小时窗口内（含同展示名不同价变体 + 1 个未定价模型）
        let fiveHourBatch = AntigravityExtractedBatch(
            sessionID: "s-5h", parentSessionID: nil, rootSessionID: nil, childCascadeIDs: [],
            steps: [
                try step("s-5h", 0, "2026-11-15T10:00:00Z", "gemini-3.8-flash-low",
                         input: 1_000_000),                                           // $0.30
                try step("s-5h", 1, "2026-11-15T10:30:00Z", "gemini-3.8-flash-high",
                         input: 1_000_000),                                           // $0.75
                try step("s-5h", 2, "2026-11-15T11:00:00Z", "gemini-9.9-ultra",
                         input: 100_000, output: 50_000),                             // 未定价
            ])

        try ledger.ingest(
            antigravity: [oldBatch, weekBatch, fiveHourBatch],
            onlineEmail: "User@Example.com",
            listenerStartedAt: listenerStartedAt)
        try ledger.rollUp(now: now, retentionDays: 30, calendar: cal)

        try expectEqual(try schemaVersion(), 5, "schema user_version 必须保持 5")
        try expectEqual(try ledger.dailyUsage().count, 2, "s-old 两个变体应分别进入 daily")

        let resets = KnownResets(
            fiveHour: try unwrap(AntigravityModelResolver.parseISO8601("2026-11-15T13:00:00Z")),
            sevenDay: try unwrap(AntigravityModelResolver.parseISO8601("2026-11-18T12:00:00Z")))
        let accountUsage = try ledger.accountUsage(
            "antigravity:user@example.com", resets: resets, now: now, calendar: cal)

        // 5 小时分段：$0.30 + $0.75 = $1.05，节省 $0.00，未定价 ["gemini-9.9-ultra"]
        let fig5h = TokenFigure(accountUsage, period: .fiveHour, kinds: TokenKind.withoutCacheWrite, includeCost: true)
        let cost5h = try unwrap(fig5h.cost)
        try expectClose(cost5h.totalCostUSD, 1.05)
        try expectEqual(cost5h.totalCostText, "≈ $1.05")
        try expectClose(cost5h.cacheSavingsUSD, 0.0)
        try expectEqual(cost5h.unpricedModels, ["gemini-9.9-ultra"])
        try expectEqual(fig5h.models.first(where: { $0.name == "Gemini 3.8 Flash" })?.costText, "$1.05")
        try expectEqual(fig5h.models.first(where: { $0.name == "gemini-9.9-ultra" })?.isUnpriced, true)
        try expectEqual(fig5h.models.first(where: { $0.name == "gemini-9.9-ultra" })?.costText, nil)

        // 周分段：$1.05 + $6.20 = $7.25，节省 $3.80
        let figWeek = TokenFigure(accountUsage, period: .sevenDay, kinds: TokenKind.withoutCacheWrite, includeCost: true)
        let costWeek = try unwrap(figWeek.cost)
        try expectClose(costWeek.totalCostUSD, 7.25)
        try expectEqual(costWeek.totalCostText, "≈ $7.25")
        try expectClose(costWeek.cacheSavingsUSD, 3.80)
        try expectEqual(costWeek.unpricedModels, ["gemini-9.9-ultra"])
        try expectEqual(figWeek.models.first(where: { $0.name == "Gemini 3.8 Flash" })?.costText, "$1.05")
        try expectEqual(figWeek.models.first(where: { $0.name == "Opus 5.5" })?.costText, "$6.20")

        // 累计分段（messages + daily）：$7.25 + $2.83 + $0.75 = $10.83，节省 $3.80 + $0.27 = $4.07
        // Gemini 3.8 Flash 累计 = $1.05 + $2.83 + $0.75 = $4.63
        let figCum = TokenFigure(accountUsage, period: .cumulative, kinds: TokenKind.withoutCacheWrite, includeCost: true)
        let costCum = try unwrap(figCum.cost)
        try expectClose(costCum.totalCostUSD, 10.83)
        try expectEqual(costCum.totalCostText, "≈ $10.83")
        try expectClose(costCum.cacheSavingsUSD, 4.07)
        try expectEqual(costCum.cacheSavingsText, "$4.07")
        try expectEqual(costCum.unpricedModels, ["gemini-9.9-ultra"])
        try expectEqual(figCum.models.first(where: { $0.name == "Gemini 3.8 Flash" })?.costText, "$4.63")
        try expectEqual(figCum.models.first(where: { $0.name == "Opus 5.5" })?.costText, "$6.20")
        try expectEqual(figCum.models.first(where: { $0.name == "gemini-9.9-ultra" })?.isUnpriced, true)

        // 清空累计后：累计归零（≈ $0.00），5h 与周费用保持不变
        try ledger.clearCumulative(account: "antigravity:user@example.com", at: now)
        let afterClear = try ledger.accountUsage(
            "antigravity:user@example.com", resets: resets, now: now, calendar: cal)
        let clearedCum = try unwrap(TokenFigure(
            afterClear, period: .cumulative, kinds: TokenKind.withoutCacheWrite, includeCost: true).cost)
        try expectClose(clearedCum.totalCostUSD, 0.0)
        try expectEqual(clearedCum.totalCostText, "≈ $0.00")
        try expectEqual(clearedCum.unpricedModels, [])
        try expectClose(TokenFigure(
            afterClear, period: .fiveHour, kinds: TokenKind.withoutCacheWrite, includeCost: true).cost?.totalCostUSD, 1.05)
        try expectClose(TokenFigure(
            afterClear, period: .sevenDay, kinds: TokenKind.withoutCacheWrite, includeCost: true).cost?.totalCostUSD, 7.25)
    }
}
