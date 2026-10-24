// ticket 12：一个额度窗口此刻该怎么显示（列表、菜单栏、ticket 13 的详情都按这套规则）。
// - 已经过了 resets_at：显示"已重置，待刷新"，不再显示旧数字；
// - 数据获取时间超过 30 分钟：数字变灰（优先于阈值颜色）；
// - 其余：颜色按剩余百分比的内置阈值（token-usage ticket 06）：≤20 红、≤50 黄、其余绿。
// 期望值来自 spec "刷新与界面"、ticket 12 的验收项和 token-usage spec 决定 10。

import Foundation

final class UsageReadingChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("还没过重置时间、数据不旧：显示剩余，颜色按剩余百分比的阈值", freshReading),
            Check("已经过了 resets_at：已重置，待刷新，不再显示旧数字", resetReading),
            Check("数据获取时间超过 30 分钟：数字变灰", staleReading),
            Check("没有窗口（utilization 为 null 等）时没有数字", missingWindow),
        ]
    }

    static let resetsLater = fixedNow.addingTimeInterval(3 * 3600)

    static func window(used: Double = 40, resetsAt: Date? = resetsLater) -> UsageWindow {
        UsageWindow(utilization: used, resetsAt: resetsAt)
    }

    static func freshReading() throws {
        let fetched = fixedNow.addingTimeInterval(-5 * 60)
        func reading(used: Double, resetsAt: Date? = resetsLater) -> UsageReading {
            UsageReading(window(used: used, resetsAt: resetsAt), fetchedAt: fetched, now: fixedNow)
        }
        try expectEqual(reading(used: 80), .remaining(20, tint: .red), "剩余 20% 算红")
        try expectEqual(reading(used: 79), .remaining(21, tint: .yellow))
        try expectEqual(reading(used: 50), .remaining(50, tint: .yellow), "剩余 50% 算黄")
        try expectEqual(reading(used: 49), .remaining(51, tint: .green))
        try expectEqual(reading(used: 100), .remaining(0, tint: .red))
        try expectEqual(reading(used: 0), .remaining(100, tint: .green))
        // 颜色跟着显示出来的数字走：已用 79.5% 显示剩余 20%，就是红色
        try expectEqual(reading(used: 79.5), .remaining(20, tint: .red), "按向下取整后的剩余判断")
        try expectEqual(reading(used: 40, resetsAt: nil), .remaining(60, tint: .green), "没有重置时间时照常显示")
    }

    static func resetReading() throws {
        let fetched = fixedNow.addingTimeInterval(-60)
        try expectEqual(UsageReading(window(resetsAt: fixedNow.addingTimeInterval(-1)),
                                     fetchedAt: fetched, now: fixedNow), .resetPendingRefresh)
        try expectEqual(UsageReading(window(resetsAt: fixedNow), fetchedAt: fetched, now: fixedNow),
                        .resetPendingRefresh, "恰好到重置时间算已重置")
        try expectEqual(UsageReading(window(resetsAt: fixedNow.addingTimeInterval(1)), fetchedAt: fetched, now: fixedNow),
                        .remaining(60, tint: .green))
        // 数据很旧、又已过重置时间：旧数字没有意义，显示已重置
        try expectEqual(UsageReading(window(resetsAt: fixedNow.addingTimeInterval(-60)),
                                     fetchedAt: fixedNow.addingTimeInterval(-7200), now: fixedNow),
                        .resetPendingRefresh)
    }

    static func staleReading() throws {
        try expectEqual(UsageReading(window(used: 90), fetchedAt: fixedNow.addingTimeInterval(-31 * 60), now: fixedNow),
                        .remaining(10, tint: .stale), "变灰优先于阈值颜色")
        try expectEqual(UsageReading(window(), fetchedAt: fixedNow.addingTimeInterval(-3 * 3600), now: fixedNow),
                        .remaining(60, tint: .stale))
        try expectEqual(UsageReading(window(used: 60), fetchedAt: fixedNow.addingTimeInterval(-30 * 60), now: fixedNow),
                        .remaining(40, tint: .yellow), "恰好 30 分钟还不算超过")
        try expectEqual(UsageReading(window(used: 60), fetchedAt: fixedNow.addingTimeInterval(-30 * 60 - 1), now: fixedNow),
                        .remaining(40, tint: .stale))
    }

    static func missingWindow() throws {
        try expectEqual(UsageReading(nil, fetchedAt: fixedNow, now: fixedNow), .unavailable)
    }
}
