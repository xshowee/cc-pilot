// ticket 07：菜单栏两行的内容。上一行当前档案名，下一行额度（ticket 11 接入前一律"—"）。

import Foundation

final class MenuBarSummaryChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("还没有额度数据时第二行显示—，有数据时显示剩余百分比", quotaLine),
            Check("已过重置时间时第二行显示已重置，不显示旧数字（ticket 12）", resetLine),
            Check("第二行的颜色与列表相同：severity、变灰；没有数字时不着色（ticket 12）", quotaTint),
            Check("第一行是当前档案记录里的名字", nameLineFollowsRecord),
        ]
    }

    static func quotaLine() throws {
        try expectEqual(MenuBarSummary(profileName: "work").quotaLine(resetText: "Reset"), "—")
        try expectEqual(MenuBarSummary(profileName: "work", fiveHour: .remaining(42, tint: .plain))
            .quotaLine(resetText: "Reset"), "42%")
        try expectEqual(MenuBarSummary(profileName: "work", fiveHour: .remaining(0, tint: .severity(.critical)))
            .quotaLine(resetText: "Reset"), "0%")
    }

    static func resetLine() throws {
        try expectEqual(MenuBarSummary(profileName: "work", fiveHour: .resetPendingRefresh)
            .quotaLine(resetText: "已重置"), "已重置")
    }

    static func quotaTint() throws {
        try expectEqual(MenuBarSummary(profileName: "w", fiveHour: .remaining(9, tint: .severity(.warning))).quotaTint,
                        .severity(.warning))
        try expectEqual(MenuBarSummary(profileName: "w", fiveHour: .remaining(9, tint: .stale)).quotaTint, .stale)
        try expectEqual(MenuBarSummary(profileName: "w", fiveHour: .remaining(9, tint: .plain)).quotaTint, .plain)
        try expectEqual(MenuBarSummary(profileName: "w", fiveHour: .resetPendingRefresh).quotaTint, .plain)
        try expectEqual(MenuBarSummary(profileName: "w").quotaTint, .plain)
    }

    static func nameLineFollowsRecord() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        let record = CurrentProfileRecord(environment: home.environment)

        try expectEqual(MenuBarSummary(record: record).profileName, "default")
        try record.switchTo("work")
        try expectEqual(MenuBarSummary(record: record).profileName, "work")
        // 在终端里用 ccp use 切换（这里直接按 ccp use 的格式写记录）
        try home.write(".claude-profiles/active", "default\n")
        try expectEqual(MenuBarSummary(record: record), MenuBarSummary(profileName: "default"))
    }
}
