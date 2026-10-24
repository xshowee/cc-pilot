// token-usage ticket 01：逐条明细的保留期 = max(35, 所有档案 settings.json 里 cleanupPeriodDays 的最大值 + 5)。
// projects/ 是共享资源，settings.json 却每个档案一份（ADR 0003），所以要看全部档案。

import Foundation

final class TokenUsageRetentionChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("没有设置 cleanupPeriodDays 时保留 35 天", defaultsTo35Days),
            Check("取所有档案里最大的 cleanupPeriodDays + 5，不少于 35 天", usesLargestCleanupPeriod),
        ]
    }

    static func defaultsTo35Days() throws {
        let home = try TempHome()
        defer { home.remove() }
        try expectEqual(TokenUsageRetention.days(environment: home.environment), 35)
        try home.makeProfileDir("work")
        try home.write(".claude/settings.json", "{\"model\":\"opus\"}")
        try home.write(".claude-profiles/work/settings.json", "不是 JSON")
        try expectEqual(TokenUsageRetention.days(environment: home.environment), 35)
    }

    static func usesLargestCleanupPeriod() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        try home.makeProfileDir("home")
        try home.writeJSON(".claude/settings.json", ["cleanupPeriodDays": 10])
        try expectEqual(TokenUsageRetention.days(environment: home.environment), 35, "10 + 5 不到 35")
        try home.writeJSON(".claude-profiles/work/settings.json", ["cleanupPeriodDays": 90])
        try home.writeJSON(".claude-profiles/home/settings.json", ["cleanupPeriodDays": 60])
        try expectEqual(TokenUsageRetention.days(environment: home.environment), 95)
    }
}
