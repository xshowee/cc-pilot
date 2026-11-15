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
}
