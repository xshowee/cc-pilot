// ticket 07：菜单栏两行的内容。上一行当前档案名，下一行额度（ticket 11 接入前一律"—"）。

import Foundation

final class MenuBarSummaryChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("还没有额度数据时第二行显示—，有数据时显示剩余百分比", quotaLine),
            Check("第一行是当前档案记录里的名字", nameLineFollowsRecord),
        ]
    }

    static func quotaLine() throws {
        try expectEqual(MenuBarSummary(profileName: "work").quotaLine, "—")
        try expectEqual(MenuBarSummary(profileName: "work", fiveHourRemaining: 42).quotaLine, "42%")
        try expectEqual(MenuBarSummary(profileName: "work", fiveHourRemaining: 0).quotaLine, "0%")
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
