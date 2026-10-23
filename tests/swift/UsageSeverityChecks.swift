// ticket 12：颜色只取自 limits[] 中对应行的 severity，App 不自己设定阈值。
// 5 小时窗口对应 kind = session，"全部模型"周窗口对应 kind = weekly_all；找不到对应的行时不着色。
// 期望值来自 spec "额度接口"的显示规则。

import Foundation

final class UsageSeverityChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("颜色取自 limits[] 中对应 kind 那一行的 severity", severityFromMatchingRow),
            Check("没有 limits[]、没有对应的行、severity 认不出时不着色", noMatchingRowNoColor),
            Check("列表和菜单栏按同一规则：颜色、超过 30 分钟变灰、过了重置时间显示已重置", boardAndMenuBarAgree),
        ]
    }

    static func boardAndMenuBarAgree() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.keychainItem(service: home.makeLoggedInProfile("solo", uuid: "u-solo"), credentialJSON(access: "token-solo"))
        // 5 小时窗口 1 小时后重置，周窗口 2 天后重置
        let body = usageJSON(fiveHour: .used(25, resetsAt: "2027-01-15T09:00:00Z"),
                             sevenDay: .used(60, resetsAt: "2027-01-17T08:00:00Z"),
                             extra: ["limits": [limit("session", "warning"), limit("weekly_all", "critical")]])
        home.transport.respond(toToken: "token-solo", body: body)
        let profiles = ProfileStore(environment: home.environment).listProfiles()
        let solo = profiles.first { $0.name == "solo" }!
        let fetched = fixedNow  // 2027-01-15T08:00:00Z
        var board = UsageBoard()
        board.record(UsageRefresher(environment: home.environment).refresh(solo.usageAccount!, in: profiles, now: fetched))

        func check(_ minutes: Double, fiveHour: UsageReading, sevenDay: UsageReading, _ what: String) throws {
            let now = fetched.addingTimeInterval(minutes * 60)
            let usage = board.usage(for: solo)
            try expectEqual(usage?.fiveHour(now: now), fiveHour, "列表 5 小时窗口：\(what)")
            try expectEqual(usage?.sevenDay(now: now), sevenDay, "列表周窗口：\(what)")
            try expectEqual(board.menuBarSummary(currentProfile: "solo", profiles: profiles, now: now).fiveHour,
                            fiveHour, "菜单栏：\(what)")
        }
        try check(10, fiveHour: .remaining(75, tint: .severity(.warning)),
                  sevenDay: .remaining(40, tint: .severity(.critical)), "刚获取")
        try check(31, fiveHour: .remaining(75, tint: .stale), sevenDay: .remaining(40, tint: .stale), "超过 30 分钟")
        try check(60, fiveHour: .resetPendingRefresh, sevenDay: .remaining(40, tint: .stale), "5 小时窗口已重置")
    }

    static func limit(_ kind: String, _ severity: Any, percent: Double = 50) -> [String: Any] {
        ["kind": kind, "percent": percent, "resets_at": NSNull(), "severity": severity]
    }

    static func parse(limits: Any?) -> UsageSnapshot? {
        var extra: [String: Any] = [:]
        if let limits { extra["limits"] = limits }
        return UsageSnapshot(json: Data(usageJSON(extra: extra).utf8), fetchedAt: fixedNow)
    }

    static func severityFromMatchingRow() throws {
        let s = parse(limits: [
            limit("weekly_scoped", "critical"),
            limit("weekly_all", "critical"),
            limit("session", "warning"),
        ])
        try expectEqual(s?.fiveHour?.severity, .warning)
        try expectEqual(s?.sevenDay?.severity, .critical)

        let normal = parse(limits: [limit("session", "normal"), limit("weekly_all", "normal")])
        try expectEqual(normal?.fiveHour?.severity, .normal)
        try expectEqual(normal?.sevenDay?.severity, .normal)
        // 颜色只来自 severity，与剩余多少无关：剩余 75% 也可以是 critical
        try expectEqual(normal?.fiveHour?.remainingPercent, 75)
    }

    static func noMatchingRowNoColor() throws {
        let none = parse(limits: nil)
        try expect(none?.fiveHour != nil && none?.fiveHour?.severity == nil, "没有 limits[] 时不着色")
        try expect(none?.sevenDay != nil && none?.sevenDay?.severity == nil, "没有 limits[] 时不着色")

        // 只有 weekly_scoped（按模型细分）的行：两个窗口都找不到对应的行
        let scopedOnly = parse(limits: [limit("weekly_scoped", "critical")])
        try expect(scopedOnly?.fiveHour?.severity == nil, "没有 session 行时 5 小时窗口不着色")
        try expect(scopedOnly?.sevenDay?.severity == nil, "没有 weekly_all 行时周窗口不着色")

        let odd = parse(limits: [limit("session", "orange"), limit("weekly_all", NSNull())])
        try expect(odd?.fiveHour?.severity == nil, "severity 认不出时不着色")
        try expect(odd?.sevenDay?.severity == nil, "severity 为 null 时不着色")

        let notArray = parse(limits: ["kind": "session", "severity": "critical"])
        try expect(notArray?.fiveHour != nil && notArray?.fiveHour?.severity == nil, "limits 不是数组时不着色")
    }
}
