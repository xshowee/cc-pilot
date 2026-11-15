// Antigravity 卡片的统计面板（ticket 05，spec "界面"统计面板、接缝 2 的"统计面板行"）。
//   StatsFlyoutRow.antigravity、rows(antigravity:)   每个邮箱一行，与其他段的同名行不相等；邮箱删除后面板收起
//   AntigravityBoard.flyout(for:now:)                面板内容：邮箱、套餐、各组圆环（按桶）与组内模型
// 只看外部行为：把刷新结果交给看板，看算出的面板内容。期望值手算：剩余 = 100 − 已用，向下取整；
// 倒计时按整分钟向上取、只保留最大的两个单位。

import Foundation

final class AntigravityStatsFlyoutChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("统计面板行：每个邮箱一行，与 Kimi Code、工具的同名行不相等；邮箱删除后面板收起", rows),
            Check("面板内容：邮箱、套餐；每组一张圆环卡，每个桶一个圆环（5 小时窗口在前），下列组内模型", content),
            Check("面板内容：只有周窗口的组一个圆环；同组同窗口重复的圆环带区分标签（同卡片）", singleAndRepeated),
            Check("旧快照的圆环变灰、倒计时照常；过了重置时间、没有数字的圆环不画弧、没有倒计时", staleAndReset),
            Check("没有卡片的邮箱（含读到但没添加的）没有面板；还没读到过、格式无法识别后的卡片只有邮箱", missingAndEmpty),
            Check("knownResets 按 Gemini -> Argon -> Carbon -> Claude & GPT 优先级独立挑选 5h 与周重置时间；缺失返回 nil", knownResetsPriority),
            Check("实时速度门控与分段不变性：仅在线非旧快照且邮箱匹配时可见；离线、旧快照或异号隐藏，分段切换不变", liveSpeedVisibilityAndPeriodInvariance),
        ]
    }

    typealias B = AntigravityBoardChecks
    static let now = fixedNow
    static func at(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    static func rows() throws {
        var board = B.added(B.ultra, B.pro)
        board.record(.success(B.ultraQuota()), clicked: nil)
        board.record(.success(B.proQuota()), clicked: nil)
        try expectEqual(board.emails, [B.ultra, B.pro])

        let ultraRow = StatsFlyoutRow.antigravity(B.ultra)
        try expectEqual(StatsFlyoutRow.rows(claudeCode: [], chatgpt: [], kimi: [B.ultra], antigravity: board.emails),
                        [StatsFlyoutRow.kimi(B.ultra), ultraRow, .antigravity(B.pro)])
        try expect(ultraRow != StatsFlyoutRow.kimi(B.ultra), "与 Kimi Code 同名的行不是同一行")
        try expect(ultraRow != StatsFlyoutRow(tool: .claudeCode, name: B.ultra), "与 Claude Code 同名的行不是同一行")

        // 格式无法识别后卡片还在（没有快照数据），仍有面板
        board.record(.unrecognizedFormat(email: B.pro), clicked: B.pro)
        try expectEqual(board.emails, [B.ultra, B.pro])

        var hover = StatsFlyoutHover()
        hover.row(ultraRow, hovering: true)
        try expectEqual(hover.row, ultraRow)
        board.remove(B.ultra)
        hover.rowsChanged(StatsFlyoutRow.rows(claudeCode: [], chatgpt: [], antigravity: board.emails))
        try expectEqual(hover.row, nil, "删除了正显示的邮箱，面板收起")
    }

    static func ring(_ remaining: Int, _ tint: UsageTint, _ countdown: ResetCountdown?) -> QuotaRing {
        QuotaRing(remaining: remaining, tint: tint, countdown: countdown)
    }

    static func content() throws {
        var board = B.added(B.ultra)
        board.record(.success(B.ultraQuota()), clicked: nil)

        // 5 分钟后：周窗口 3 天后重置 → 还剩 2 天 23 小时 55 分；5 小时窗口 133 分钟后 → 还剩 2 小时 8 分
        let flyout = try unwrap(board.flyout(for: B.ultra, now: at(minutes: 5)))
        try expectEqual(flyout.email, B.ultra)
        try expectEqual(flyout.tierName, "Google AI Ultra")
        try expectEqual(flyout.isOldSnapshot, false)
        try expectEqual(flyout.groups.map(\.display.kind), [.gemini, .thirdParty])
        try expectEqual(flyout.groups.map(\.display.models), [["Gemini 3 Pro", "Gemini 3 Flash"], ["Claude Opus 4.5"]])
        try expectEqual(flyout.groups.map { $0.rings.map(\.bucket.window) }, [[.fiveHour, .weekly], [.fiveHour, .weekly]])
        try expectEqual(flyout.groups.map { $0.rings.map(\.ring) }, [
            [ring(71, .green, .hoursMinutes(2, 8)), ring(92, .green, .daysHours(2, 23))],
            [ring(15, .red, .minutes(55)), ring(40, .yellow, .daysHours(1, 23))],
        ])
    }

    static func singleAndRepeated() throws {
        var board = B.added(B.pro)
        board.record(.success(B.proQuota()), clicked: nil)
        let pro = try unwrap(board.flyout(for: B.pro, now: now))
        try expectEqual(pro.tierName, "Google AI Pro")
        try expectEqual(pro.groups.count, 1)
        try expectEqual(pro.groups[0].display.displayName, "Gemini 4 Argon")
        try expectEqual(pro.groups[0].display.models, [])
        try expectEqual(pro.groups[0].rings.map(\.ring), [ring(64, .green, .daysHours(1, 0))])

        let repeated = AntigravityAccountQuota(
            email: B.pro, tierName: "Google AI Pro", tierId: "g1-pro-tier",
            groups: [AntigravityQuotaGroup(
                kind: .gemini, displayName: "Gemini Models", models: [],
                buckets: [B.bucket("gemini-5h", .fiveHour, remaining: 50, resetIn: 30),
                          B.bucket("gemini-weekly", .weekly, remaining: 60, resetIn: 30),
                          B.bucket("argon-weekly", .weekly, remaining: 70, resetIn: 30, name: "Argon Weekly Limit")])],
            fetchedAt: now)
        board.record(.success(repeated), clicked: nil)
        let rings = try unwrap(board.flyout(for: B.pro, now: now)).groups[0].rings
        try expectEqual(rings.map(\.bucket.extraLabel), [nil, nil, "Argon Weekly Limit"])
        try expectEqual(rings.map(\.ring), [ring(50, .yellow, .minutes(30)), ring(60, .green, .minutes(30)),
                                             ring(70, .green, .minutes(30))])
    }

    static func staleAndReset() throws {
        var board = B.added(B.ultra, B.pro)
        board.record(.success(B.ultraQuota()), clicked: nil)
        board.record(.success(B.proQuota()), clicked: nil)

        // ultra 不是最后读到的：数字变灰，倒计时照常（10 分钟后：5 小时窗口还剩 2 小时 3 分）
        let old = try unwrap(board.flyout(for: B.ultra, now: at(minutes: 10)))
        try expectEqual(old.isOldSnapshot, true)
        try expectEqual(old.groups[0].rings.map(\.ring),
                        [ring(71, .stale, .hoursMinutes(2, 3)), ring(92, .stale, .daysHours(2, 23))])

        // 61 分钟后：3p-5h（60 分钟后重置）已重置 → 不画弧、没有倒计时，不显示灰的旧数字
        try expectEqual(try unwrap(board.flyout(for: B.ultra, now: at(minutes: 61))).groups[1].rings.map(\.ring),
                        [.empty, ring(40, .stale, .daysHours(1, 22))])

        // 最后读到的同样按重置时间：1441 分钟后 argon-weekly 已重置
        try expectEqual(try unwrap(board.flyout(for: B.pro, now: at(minutes: 1441))).groups[0].rings.map(\.ring),
                        [.empty])

        // 没有数字的桶
        let empty = AntigravityAccountQuota(
            email: B.pro, tierName: nil, tierId: nil,
            groups: [AntigravityQuotaGroup(kind: .other, displayName: "Empty", models: [],
                                           buckets: [B.bucket("empty-5h", .fiveHour, remaining: nil)])],
            fetchedAt: now)
        board.record(.success(empty), clicked: nil)
        let flyout = try unwrap(board.flyout(for: B.pro, now: now))
        try expectEqual(flyout.tierName, nil)
        try expectEqual(flyout.groups[0].rings.map(\.ring), [.empty])
    }

    static func missingAndEmpty() throws {
        try expectEqual(AntigravityBoard().flyout(for: B.ultra, now: now), nil)
        var board = B.added(B.ultra)
        // 还没读到过：只有邮箱
        var flyout = try unwrap(board.flyout(for: B.ultra, now: now))
        try expectEqual(flyout.email, B.ultra)
        try expectEqual(flyout.tierName, nil)
        try expectEqual(flyout.groups, [])

        // 读到没添加的邮箱：它没有卡片，也没有面板
        board.record(.success(B.proQuota()), clicked: nil)
        try expectEqual(board.flyout(for: B.pro, now: now), nil)

        board.record(.success(B.ultraQuota()), clicked: nil)
        board.record(.unrecognizedFormat(email: B.ultra), clicked: B.ultra)
        flyout = try unwrap(board.flyout(for: B.ultra, now: now))
        try expectEqual(flyout.email, B.ultra)
        try expectEqual(flyout.tierName, nil)
        try expectEqual(flyout.groups, [])

        board.remove(B.ultra)
        try expectEqual(board.flyout(for: B.ultra, now: now), nil)
    }

    static func knownResetsPriority() throws {
        // 未添加/无快照 -> nil
        try expectEqual(AntigravityBoard().knownResets(for: B.ultra), KnownResets(fiveHour: nil, sevenDay: nil))

        let gemini5h = at(minutes: 100)
        let argon5h = at(minutes: 200)
        let argonWeekly = at(minutes: 300)
        let carbon5h = at(minutes: 400)
        let carbonWeekly = at(minutes: 500)
        let thirdParty5h = at(minutes: 600)
        let thirdPartyWeekly = at(minutes: 700)

        func bucket(_ id: String, _ window: AntigravityQuotaBucket.Window, resetsAt: Date?) -> AntigravityQuotaBucket {
            AntigravityQuotaBucket(
                bucketId: id, displayName: nil, window: window,
                usage: resetsAt.map { UsageWindow(utilization: 10, resetsAt: $0) })
        }

        // 1) Gemini 仅 5h、Argon 有 5h+weekly、Carbon 有 weekly、Claude & GPT 有 5h+weekly
        // 接口顺序故意倒序放，验证按池优先级而不是按接口顺序
        var board = B.added("User@Example.com")
        board.record(.success(AntigravityAccountQuota(
            email: "user@example.com", tierName: "Pro", tierId: nil,
            groups: [
                AntigravityQuotaGroup(kind: .thirdParty, displayName: "Claude and GPT models", models: [],
                                      buckets: [bucket("3p-5h", .fiveHour, resetsAt: thirdParty5h),
                                                bucket("3p-w", .weekly, resetsAt: thirdPartyWeekly)]),
                AntigravityQuotaGroup(kind: .other, displayName: "Gemini 4 Carbon", models: [],
                                      buckets: [bucket("c-w", .weekly, resetsAt: carbonWeekly)]),
                AntigravityQuotaGroup(kind: .other, displayName: "Gemini 4 Argon", models: [],
                                      buckets: [bucket("a-5h", .fiveHour, resetsAt: argon5h),
                                                bucket("a-w", .weekly, resetsAt: argonWeekly)]),
                AntigravityQuotaGroup(kind: .gemini, displayName: "Gemini Models", models: [],
                                      buckets: [bucket("g-5h", .fiveHour, resetsAt: gemini5h)]),
            ],
            fetchedAt: now)), clicked: nil)

        try expectEqual(board.knownResets(for: "USER@example.com"),
                        KnownResets(fiveHour: gemini5h, sevenDay: argonWeekly),
                        "5h 取 Gemini，周独立取次高优先级 Argon（忽略大小写）")

        // 2) 没有 Gemini，Argon 只有 5h，Carbon 有 5h + weekly -> 5h 取 Argon，周取 Carbon
        board.record(.success(AntigravityAccountQuota(
            email: "user@example.com", tierName: "Pro", tierId: nil,
            groups: [
                AntigravityQuotaGroup(kind: .thirdParty, displayName: "Claude and GPT models", models: [],
                                      buckets: [bucket("3p-5h", .fiveHour, resetsAt: thirdParty5h),
                                                bucket("3p-w", .weekly, resetsAt: thirdPartyWeekly)]),
                AntigravityQuotaGroup(kind: .other, displayName: "Gemini 4 Carbon", models: [],
                                      buckets: [bucket("c-5h", .fiveHour, resetsAt: carbon5h),
                                                bucket("c-w", .weekly, resetsAt: carbonWeekly)]),
                AntigravityQuotaGroup(kind: .other, displayName: "Gemini 4 Argon", models: [],
                                      buckets: [bucket("a-5h", .fiveHour, resetsAt: argon5h)]),
            ],
            fetchedAt: now)), clicked: nil)

        try expectEqual(board.knownResets(for: "user@example.com"),
                        KnownResets(fiveHour: argon5h, sevenDay: carbonWeekly))

        // 3) 未知 other 组不参与，仅 thirdParty 有 weekly -> fiveHour=nil, sevenDay=thirdPartyWeekly
        board.record(.success(AntigravityAccountQuota(
            email: "user@example.com", tierName: nil, tierId: nil,
            groups: [
                AntigravityQuotaGroup(kind: .other, displayName: "Gemini 4 Hydrogen", models: [],
                                      buckets: [bucket("h-5h", .fiveHour, resetsAt: at(minutes: 999))]),
                AntigravityQuotaGroup(kind: .thirdParty, displayName: "Claude and GPT models", models: [],
                                      buckets: [bucket("3p-w", .weekly, resetsAt: thirdPartyWeekly)]),
            ],
            fetchedAt: now)), clicked: nil)

        try expectEqual(board.knownResets(for: "user@example.com"),
                        KnownResets(fiveHour: nil, sevenDay: thirdPartyWeekly))

        // 4) 格式无法识别丢弃快照后回到 nil
        board.record(.unrecognizedFormat(email: "user@example.com"), clicked: "user@example.com")
        try expectEqual(board.knownResets(for: "user@example.com"), KnownResets(fiveHour: nil, sevenDay: nil))
    }

    static func liveSpeedVisibilityAndPeriodInvariance() throws {
        var board = B.added(B.ultra, B.pro)
        board.record(.success(B.ultraQuota()), clicked: nil)

        let ultraSpeed = AntigravityLiveSpeed(
            email: B.ultra.lowercased(),
            latestTokPerSec: 42.5,
            latestTtftSec: 0.8,
            sessionAvgTokPerSec: 38.1)

        // 1) 当前非旧快照 + 邮箱一致（忽略大小写）-> 可见
        let shown = try unwrap(board.flyout(for: B.ultra, now: now, liveSpeed: AntigravityLiveSpeed(
            email: B.ultra.uppercased(),
            latestTokPerSec: 42.5,
            latestTtftSec: 0.8,
            sessionAvgTokPerSec: 38.1)))
        try expectEqual(shown.isOldSnapshot, false)
        try expectEqual(shown.visibleLiveSpeed?.latestTokPerSec, 42.5)
        try expectEqual(shown.visibleLiveSpeed?.latestTtftSec, 0.8)
        try expectEqual(shown.visibleLiveSpeed?.sessionAvgTokPerSec, 38.1)

        // 2) 分段切换（5h / 周 / 累计）不影响 visibleLiveSpeed
        let usage = AccountTokenUsage(
            fiveHour: TokenUsageWindow(start: now.addingTimeInterval(-3600), end: now, usage: TokenUsageBreakdown(tokens: TokenCounts(input: 10, output: 20, cacheWrite: 0, cacheRead: 30), byModel: [])),
            sevenDay: TokenUsageWindow(start: now.addingTimeInterval(-86400), end: now, usage: TokenUsageBreakdown(tokens: TokenCounts(input: 100, output: 200, cacheWrite: 0, cacheRead: 300), byModel: [])),
            cumulative: TokenUsageCumulative(origin: now.addingTimeInterval(-86400), usage: TokenUsageBreakdown(tokens: TokenCounts(input: 1000, output: 2000, cacheWrite: 0, cacheRead: 3000), byModel: [])),
            hourly: [],
            daily: [])
        let figures = TokenUsagePeriod.allCases.map { TokenFigure(usage, period: $0, kinds: TokenKind.withoutCacheWrite) }
        try expectEqual(figures.map(\.total), ["60", "600", "6.0K"])
        for _ in figures {
            let f = try unwrap(board.flyout(for: B.ultra, now: now, liveSpeed: ultraSpeed))
            try expectEqual(f.visibleLiveSpeed, ultraSpeed, "切换 5h/周/累计 时实时速度不得变化")
        }

        // 3) 离线（nil）-> 隐藏
        try expectEqual(try unwrap(board.flyout(for: B.ultra, now: now, liveSpeed: nil)).visibleLiveSpeed, nil)

        // 4) 邮箱不匹配 -> 隐藏
        let proSpeed = AntigravityLiveSpeed(
            email: B.pro.lowercased(),
            latestTokPerSec: 60.0,
            latestTtftSec: nil,
            sessionAvgTokPerSec: 55.0)
        try expectEqual(try unwrap(board.flyout(for: B.ultra, now: now, liveSpeed: proSpeed)).visibleLiveSpeed, nil)

        // 5) 切换到 pro 后，ultra 变为旧快照（isOldSnapshot == true）-> 即使传入 ultraSpeed 也必须隐藏
        board.record(.success(B.proQuota()), clicked: nil)
        let staleUltra = try unwrap(board.flyout(for: B.ultra, now: now, liveSpeed: ultraSpeed))
        try expectEqual(staleUltra.isOldSnapshot, true)
        try expectEqual(staleUltra.visibleLiveSpeed, nil, "旧快照卡片不得显示实时速度")

        // 当前卡片 pro 与 proSpeed 一致 -> 可见
        let currentPro = try unwrap(board.flyout(for: B.pro, now: now, liveSpeed: proSpeed))
        try expectEqual(currentPro.visibleLiveSpeed, proSpeed)

        // 6) 从未读过的新增卡片（isOldSnapshot == true）-> 隐藏
        board.add("fresh@example.com")
        let freshSpeed = AntigravityLiveSpeed(email: "fresh@example.com", latestTokPerSec: 12, latestTtftSec: nil, sessionAvgTokPerSec: 12)
        try expectEqual(try unwrap(board.flyout(for: "fresh@example.com", now: now, liveSpeed: freshSpeed)).visibleLiveSpeed, nil)
    }
}
