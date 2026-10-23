// ticket 12：一个额度窗口此刻该怎么显示（列表、菜单栏、ticket 13 的详情都按这套规则）。
// - 已经过了 resets_at：显示"已重置，待刷新"，不再显示旧数字；
// - 数据获取时间超过 30 分钟：数字变灰（优先于 severity 的颜色）；
// - 其余：颜色取自 severity，没有 severity 时不着色。
// 期望值来自 spec "刷新与界面"和 ticket 12 的验收项。

import Foundation

final class UsageReadingChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("还没过重置时间、数据不旧：显示剩余，颜色取自 severity，没有时不着色", freshReading),
            Check("已经过了 resets_at：已重置，待刷新，不再显示旧数字", resetReading),
            Check("数据获取时间超过 30 分钟：数字变灰", staleReading),
            Check("没有窗口（utilization 为 null 等）时没有数字", missingWindow),
        ]
    }

    static let resetsLater = fixedNow.addingTimeInterval(3 * 3600)

    static func window(used: Double = 40, resetsAt: Date? = resetsLater, _ severity: UsageSeverity? = nil) -> UsageWindow {
        UsageWindow(utilization: used, resetsAt: resetsAt, severity: severity)
    }

    static func freshReading() throws {
        let fetched = fixedNow.addingTimeInterval(-5 * 60)
        try expectEqual(UsageReading(window(.critical), fetchedAt: fetched, now: fixedNow),
                        .remaining(60, tint: .severity(.critical)))
        try expectEqual(UsageReading(window(.normal), fetchedAt: fetched, now: fixedNow),
                        .remaining(60, tint: .severity(.normal)))
        try expectEqual(UsageReading(window(nil), fetchedAt: fetched, now: fixedNow),
                        .remaining(60, tint: .plain), "没有 severity 时不着色")
        try expectEqual(UsageReading(window(resetsAt: nil, .warning), fetchedAt: fetched, now: fixedNow),
                        .remaining(60, tint: .severity(.warning)), "没有重置时间时照常显示")
    }

    static func resetReading() throws {
        let fetched = fixedNow.addingTimeInterval(-60)
        try expectEqual(UsageReading(window(resetsAt: fixedNow.addingTimeInterval(-1), .critical),
                                     fetchedAt: fetched, now: fixedNow), .resetPendingRefresh)
        try expectEqual(UsageReading(window(resetsAt: fixedNow), fetchedAt: fetched, now: fixedNow),
                        .resetPendingRefresh, "恰好到重置时间算已重置")
        try expectEqual(UsageReading(window(resetsAt: fixedNow.addingTimeInterval(1)), fetchedAt: fetched, now: fixedNow),
                        .remaining(60, tint: .plain))
        // 数据很旧、又已过重置时间：旧数字没有意义，显示已重置
        try expectEqual(UsageReading(window(resetsAt: fixedNow.addingTimeInterval(-60)),
                                     fetchedAt: fixedNow.addingTimeInterval(-7200), now: fixedNow),
                        .resetPendingRefresh)
    }

    static func staleReading() throws {
        try expectEqual(UsageReading(window(.critical), fetchedAt: fixedNow.addingTimeInterval(-31 * 60), now: fixedNow),
                        .remaining(60, tint: .stale), "变灰优先于 severity 的颜色")
        try expectEqual(UsageReading(window(nil), fetchedAt: fixedNow.addingTimeInterval(-3 * 3600), now: fixedNow),
                        .remaining(60, tint: .stale))
        try expectEqual(UsageReading(window(.warning), fetchedAt: fixedNow.addingTimeInterval(-30 * 60), now: fixedNow),
                        .remaining(60, tint: .severity(.warning)), "恰好 30 分钟还不算超过")
        try expectEqual(UsageReading(window(.warning), fetchedAt: fixedNow.addingTimeInterval(-30 * 60 - 1), now: fixedNow),
                        .remaining(60, tint: .stale))
    }

    static func missingWindow() throws {
        try expectEqual(UsageReading(nil, fetchedAt: fixedNow, now: fixedNow), .unavailable)
    }
}
