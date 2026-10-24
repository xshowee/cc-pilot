// token-usage ticket 06：额度颜色用内置阈值，所有地方统一（spec 决定 10）：
// 剩余 ≤20% 红、≤50% 黄、其余绿（与 ~/.claude/statusline.sh 的已用 ≥80 / ≥50 一致）；
// 不再使用服务端 limits[].severity。数据超过 30 分钟变灰的规则不变。

import Foundation

final class UsageThresholdChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("剩余 ≤20% 红、≤50% 黄、其余绿（边界 20 / 21、50 / 51）", thresholdBoundaries),
            Check("不看 limits[] 的 severity：颜色只按剩余百分比", serverSeverityIgnored),
            Check("列表、菜单栏、按模型周窗口按同一规则：阈值颜色、超过 30 分钟变灰、过了重置时间显示已重置",
                  boardAndMenuBarAgree),
        ]
    }

    static func thresholdBoundaries() throws {
        try expectEqual(UsageTint(remainingPercent: 0), .red)
        try expectEqual(UsageTint(remainingPercent: 20), .red, "恰好 20% 算红")
        try expectEqual(UsageTint(remainingPercent: 21), .yellow)
        try expectEqual(UsageTint(remainingPercent: 50), .yellow, "恰好 50% 算黄")
        try expectEqual(UsageTint(remainingPercent: 51), .green)
        try expectEqual(UsageTint(remainingPercent: 100), .green)
    }

    static func limit(_ kind: String, _ severity: Any, percent: Double = 50) -> [String: Any] {
        ["kind": kind, "percent": percent, "resets_at": NSNull(), "severity": severity]
    }

    static func serverSeverityIgnored() throws {
        // 已用 25%（剩余 75%）和 60%（剩余 40%），服务端却分别说 critical 和 normal
        let body = usageJSON(fiveHour: .used(25, resetsAt: "2027-01-15T09:00:00Z"),
                             sevenDay: .used(60, resetsAt: "2027-01-17T08:00:00Z"),
                             extra: ["limits": [limit("session", "critical"), limit("weekly_all", "normal"),
                                                limit("weekly_scoped", "normal", percent: 85)]])
        let usage = AccountUsage(snapshot: UsageSnapshot(json: Data(body.utf8), fetchedAt: fixedNow), problem: nil, retryAt: nil)
        try expectEqual(usage.fiveHour(now: fixedNow), .remaining(75, tint: .green), "剩余 75% 是绿色，不管 severity")
        try expectEqual(usage.sevenDay(now: fixedNow), .remaining(40, tint: .yellow))
        try expectEqual(usage.modelWeekly(now: fixedNow).map(\.reading), [.remaining(15, tint: .red)])
    }

    static func boardAndMenuBarAgree() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.keychainItem(service: home.makeLoggedInProfile("solo", uuid: "u-solo"), credentialJSON(access: "token-solo"))
        // 5 小时窗口 1 小时后重置，周窗口 2 天后重置
        let body = usageJSON(fiveHour: .used(85, resetsAt: "2027-01-15T09:00:00Z"),
                             sevenDay: .used(60, resetsAt: "2027-01-17T08:00:00Z"),
                             extra: ["limits": [limit("weekly_scoped", "critical", percent: 30)]])
        home.transport.respond(toToken: "token-solo", body: body)
        let profiles = ProfileStore(environment: home.environment).listProfiles()
        let solo = profiles.first { $0.name == "solo" }!
        let fetched = fixedNow  // 2027-01-15T08:00:00Z
        var board = UsageBoard()
        board.record(UsageRefresher(environment: home.environment).refresh(solo.usageAccount!, in: profiles, now: fetched))

        func check(_ minutes: Double, fiveHour: UsageReading, sevenDay: UsageReading, model: UsageReading,
                   _ what: String) throws {
            let now = fetched.addingTimeInterval(minutes * 60)
            let usage = board.usage(for: solo)
            try expectEqual(usage?.fiveHour(now: now), fiveHour, "列表 5 小时窗口：\(what)")
            try expectEqual(usage?.sevenDay(now: now), sevenDay, "列表周窗口：\(what)")
            try expectEqual(usage?.modelWeekly(now: now).map(\.reading), [model], "按模型周窗口：\(what)")
            try expectEqual(board.menuBarSummary(currentProfile: "solo", profiles: profiles, now: now).fiveHour,
                            fiveHour, "菜单栏：\(what)")
        }
        try check(10, fiveHour: .remaining(15, tint: .red), sevenDay: .remaining(40, tint: .yellow),
                  model: .remaining(70, tint: .green), "刚获取")
        try check(31, fiveHour: .remaining(15, tint: .stale), sevenDay: .remaining(40, tint: .stale),
                  model: .remaining(70, tint: .stale), "超过 30 分钟")
        try check(60, fiveHour: .resetPendingRefresh, sevenDay: .remaining(40, tint: .stale),
                  model: .remaining(70, tint: .stale), "5 小时窗口已重置")
    }
}
