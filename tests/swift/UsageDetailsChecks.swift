// ticket 13：展开账号后看到的额度详情——按模型细分的周窗口、超额付费（extra_usage）。
// 期望值来自 spec "额度接口"一节和 ticket 13 的验收项；过期、已重置、着色沿用 ticket 12 的 UsageReading
// （颜色按 token-usage ticket 06 的内置阈值，fixture 里的 severity 只是真实响应里会有的字段，不影响颜色）。

import Foundation

final class UsageDetailsChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("limits[] 中每一行 weekly_scoped 各是一个按模型的周窗口", scopedRowsAreModelWindows),
            Check("按模型周窗口的 resets_at：ISO 时间或秒时间戳", scopedResetTimes),
            Check("按模型周窗口遵守过期规则：超过 30 分钟变灰，过了重置时间显示已重置", scopedFollowStaleRules),
            Check("没有 limits[] 时回退到顶层 seven_day_sonnet、seven_day_opus", fallbackToTopLevelModelWindows),
            Check("超额付费：开启时有月度上限（null 为不限）和已使用金额，没开启时为未开启", extraUsageStates),
            Check("超额付费金额按币种的最小单位换算并格式化", extraUsageAmounts),
            Check("超额付费遵守过期规则：超过 30 分钟变灰，格式无法识别时不显示", extraUsageFollowsStaleRules),
        ]
    }

    static func scoped(_ model: Any?, percent: Any, resetsAt: Any = NSNull(), severity: Any = "normal") -> [String: Any] {
        var row: [String: Any] = ["kind": "weekly_scoped", "percent": percent, "resets_at": resetsAt, "severity": severity]
        if let model { row["scope"] = ["model": ["display_name": model]] }
        return row
    }

    static func parse(_ extra: [String: Any]) -> UsageSnapshot? {
        UsageSnapshot(json: Data(usageJSON(extra: extra).utf8), fetchedAt: fixedNow)
    }

    /// 刚获取（fixedNow）的数据，在 now 时刻怎么显示
    static func usage(_ extra: [String: Any]) -> AccountUsage {
        AccountUsage(snapshot: parse(extra), problem: nil, retryAt: nil)
    }

    static func scopedRowsAreModelWindows() throws {
        let u = usage(["limits": [
            ["kind": "session", "percent": 10, "resets_at": NSNull(), "severity": "critical"],
            scoped("Opus", percent: 80, resetsAt: "2027-01-20T09:30:00Z", severity: "critical"),
            ["kind": "weekly_all", "percent": 10, "resets_at": NSNull(), "severity": "normal"],
            scoped("Sonnet", percent: 37.5, severity: "warning"),
        ]])
        let readings = u.modelWeekly(now: fixedNow)
        try expectEqual(readings.map(\.model), ["Opus", "Sonnet"], "标题取 scope.model.display_name，按 limits[] 顺序")
        try expectEqual(readings.map(\.reading), [.remaining(20, tint: .red), .remaining(62, tint: .green)],
                        "剩余 = 100 − percent，颜色按剩余百分比的阈值")
        try expectEqual(readings.first?.resetsAt, Date(timeIntervalSince1970: 1_800_437_400))
        try expectEqual(readings.last?.resetsAt, nil)

        let odd = usage(["limits": [scoped("Haiku", percent: 5, severity: "purple"),
                                    scoped("Opus", percent: NSNull()),
                                    scoped(nil, percent: 30)]]).modelWeekly(now: fixedNow)
        try expectEqual(odd.map(\.reading), [.remaining(95, tint: .green), .remaining(70, tint: .green)],
                        "percent 不是数字的行不显示")
        try expectEqual(odd.map(\.model), ["Haiku", nil], "没有 display_name 时标题为 nil（界面用通用标题）")
    }

    static func scopedResetTimes() throws {
        let readings = usage(["limits": [
            scoped("A", percent: 1, resetsAt: "2027-01-20T17:30:00.943648+08:00"),
            scoped("B", percent: 1, resetsAt: 1_800_437_400),
            scoped("C", percent: 1, resetsAt: 1_800_437_400.5),
            scoped("D", percent: 1, resetsAt: "next week"),
        ]]).modelWeekly(now: fixedNow)
        try expectEqual(readings.map(\.resetsAt), [Date(timeIntervalSince1970: 1_800_437_400),
                                                   Date(timeIntervalSince1970: 1_800_437_400),
                                                   Date(timeIntervalSince1970: 1_800_437_400.5),
                                                   nil])
        try expectEqual(readings.last?.reading, .remaining(99, tint: .green), "resets_at 认不出时照常显示")
    }

    static func scopedFollowStaleRules() throws {
        // fixedNow = 2027-01-15T08:00:00Z；Opus 1 小时后重置，Sonnet 以秒时间戳给出，2 天后重置
        let u = usage(["limits": [scoped("Opus", percent: 40, resetsAt: "2027-01-15T09:00:00Z", severity: "warning"),
                                  scoped("Sonnet", percent: 90, resetsAt: 1_800_172_800, severity: "critical")]])
        func readings(_ minutes: Double) -> [UsageReading] {
            u.modelWeekly(now: fixedNow.addingTimeInterval(minutes * 60)).map(\.reading)
        }
        try expectEqual(readings(30), [.remaining(60, tint: .green), .remaining(10, tint: .red)])
        try expectEqual(readings(31), [.remaining(60, tint: .stale), .remaining(10, tint: .stale)], "超过 30 分钟变灰")
        try expectEqual(readings(60), [.resetPendingRefresh, .remaining(10, tint: .stale)], "已过 resets_at")
        try expectEqual(readings(2 * 24 * 60), [.resetPendingRefresh, .resetPendingRefresh], "秒时间戳也按重置时间判断")

        var broken = u
        broken.problem = .unrecognizedFormat
        try expectEqual(broken.modelWeekly(now: fixedNow).count, 0, "格式无法识别时不显示旧数字")
    }

    static func fallbackToTopLevelModelWindows() throws {
        let sonnet: [String: Any] = ["utilization": 30, "resets_at": "2027-01-15T09:00:00Z"]
        let opus: [String: Any] = ["utilization": 75.5, "resets_at": 1_800_437_400]
        for limits in [nil, NSNull(), [] as [Any]] as [Any?] {
            var extra: [String: Any] = ["seven_day_sonnet": sonnet, "seven_day_opus": opus]
            if let limits { extra["limits"] = limits }
            let readings = usage(extra).modelWeekly(now: fixedNow)
            try expectEqual(readings, [
                ModelWeeklyReading(model: "Sonnet", reading: .remaining(70, tint: .green),
                                   resetsAt: Date(timeIntervalSince1970: 1_800_003_600)),
                ModelWeeklyReading(model: "Opus", reading: .remaining(24, tint: .yellow),
                                   resetsAt: Date(timeIntervalSince1970: 1_800_437_400)),
            ], "limits = \(String(describing: limits))")
            try expectEqual(usage(extra).modelWeekly(now: fixedNow.addingTimeInterval(31 * 60)).map(\.reading),
                            [.remaining(70, tint: .stale), .remaining(24, tint: .stale)], "回退的窗口也遵守过期规则")
        }

        let onlyOpus = usage(["seven_day_sonnet": ["utilization": NSNull(), "resets_at": NSNull()], "seven_day_opus": opus])
        try expectEqual(onlyOpus.modelWeekly(now: fixedNow).map(\.model), ["Opus"], "utilization 为 null 的窗口不显示")
        try expectEqual(usage([:]).modelWeekly(now: fixedNow).count, 0, "两个都没有时不显示")

        // 有 limits[] 时以它为准，不再回退（即使里面没有 weekly_scoped 行）
        let withLimits = usage(["seven_day_sonnet": sonnet, "seven_day_opus": opus,
                                "limits": [["kind": "session", "percent": 1, "severity": "normal"]]])
        try expectEqual(withLimits.modelWeekly(now: fixedNow).count, 0)
    }

    static func extra(_ fields: [String: Any]) -> [String: Any] {
        ["extra_usage": fields]
    }

    static func extraUsageStates() throws {
        let capped = parse(extra(["is_enabled": true, "monthly_limit": 5000, "used_credits": 1234,
                                  "utilization": 24.68, "currency": "USD"]))
        try expectEqual(capped?.extraUsage, .enabled(monthlyLimit: CreditAmount(minorUnits: 5000, currency: "USD"),
                                                     used: CreditAmount(minorUnits: 1234, currency: "USD")))
        let unlimited = parse(extra(["is_enabled": true, "monthly_limit": NSNull(), "used_credits": 0,
                                     "utilization": NSNull(), "currency": "USD"]))
        try expectEqual(unlimited?.extraUsage, .enabled(monthlyLimit: nil, used: CreditAmount(minorUnits: 0, currency: "USD")),
                        "monthly_limit 为 null 表示不限")
        let off = parse(extra(["is_enabled": false, "monthly_limit": NSNull(), "used_credits": NSNull(),
                               "utilization": NSNull(), "currency": NSNull()]))
        try expectEqual(off?.extraUsage, .disabled)
        try expect(parse(["extra_usage": NSNull()])?.extraUsage == nil, "extra_usage 为 null 时不显示")
        try expect(parse([:])?.extraUsage == nil, "没有 extra_usage 时不显示")
        try expect(parse(extra(["is_enabled": "yes"]))?.extraUsage == nil, "is_enabled 不是布尔值时不显示")
        try expectEqual(parse(extra(["is_enabled": true, "used_credits": NSNull(), "currency": "USD"]))?.extraUsage,
                        .enabled(monthlyLimit: nil, used: nil), "没给已使用金额时为 nil（界面显示—）")
    }

    static func extraUsageAmounts() throws {
        let cases: [(Double, String?, Decimal?, String?)] = [
            (1234, "USD", Decimal(string: "12.34"), "$12.34"),     // 美分 → 美元
            (5000, "usd", 50, "$50.00"),                           // 币种代码大小写都认
            (500, "JPY", 500, "¥500"),                             // 日元没有更小的单位
            (1500, "KWD", Decimal(string: "1.5"), "KWD\u{00A0}1.500"),  // 第纳尔的最小单位是 1/1000（符号后是不换行空格）
            (100, nil, nil, nil),                                  // 没给币种：不猜
            (100, "XYZ", nil, nil),                                // 认不出的币种：不猜
        ]
        let enUS = Locale(identifier: "en_US")
        for (minor, currency, major, text) in cases {
            let amount = CreditAmount(minorUnits: minor, currency: currency)
            try expectEqual(amount.majorUnits, major, "\(minor) \(currency ?? "nil")")
            try expectEqual(UsageDisplay.money(amount, locale: enUS), text, "\(minor) \(currency ?? "nil")")
        }
        try expectEqual(UsageDisplay.money(CreditAmount(minorUnits: 123456, currency: "USD"), locale: Locale(identifier: "zh_CN")),
                        "US$1,234.56")
    }

    static func extraUsageFollowsStaleRules() throws {
        let u = usage(extra(["is_enabled": true, "monthly_limit": 5000, "used_credits": 1234, "currency": "USD"]))
        let enabled = ExtraUsage.enabled(monthlyLimit: CreditAmount(minorUnits: 5000, currency: "USD"),
                                         used: CreditAmount(minorUnits: 1234, currency: "USD"))
        try expectEqual(u.extraUsage(now: fixedNow.addingTimeInterval(30 * 60)), ExtraUsageReading(usage: enabled, tint: .plain))
        try expectEqual(u.extraUsage(now: fixedNow.addingTimeInterval(31 * 60)), ExtraUsageReading(usage: enabled, tint: .stale),
                        "超过 30 分钟变灰")
        try expectEqual(usage(extra(["is_enabled": false])).extraUsage(now: fixedNow),
                        ExtraUsageReading(usage: .disabled, tint: .plain))
        try expect(usage([:]).extraUsage(now: fixedNow) == nil, "没有 extra_usage 时不显示")
        var broken = u
        broken.problem = .unrecognizedFormat
        try expect(broken.extraUsage(now: fixedNow) == nil, "格式无法识别时不显示旧数字")
        try expect(AccountUsage().extraUsage(now: fixedNow) == nil, "没有数据时不显示")
    }
}
