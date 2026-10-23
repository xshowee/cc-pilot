// ticket 11：解析额度接口的响应。剩余百分比 = 100 − utilization；utilization 为 null 的窗口不显示。
// 期望值来自 spec "额度接口"一节。

import Foundation

final class UsageSnapshotChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("剩余百分比等于 100 减去 utilization", remainingIsHundredMinusUtilization),
            Check("utilization 为 null 或缺失的窗口不显示", nullWindowsHidden),
            Check("重置时间：ISO 时间（含 6 位小数秒）、秒时间戳、null", resetTimes),
            Check("一个已知的顶层字段都没有、或不是 JSON 对象：格式无法识别", unrecognizedFormat),
        ]
    }

    static func parse(_ body: String) -> UsageSnapshot? {
        UsageSnapshot(json: Data(body.utf8), fetchedAt: fixedNow)
    }

    static func remainingIsHundredMinusUtilization() throws {
        let s = parse(usageJSON(fiveHour: .used(25, resetsAt: nil), sevenDay: .used(60, resetsAt: nil)))
        try expectEqual(s?.fiveHour?.remainingPercent, 75)
        try expectEqual(s?.sevenDay?.remainingPercent, 40)
        try expectEqual(s?.fetchedAt, fixedNow)
        let cases: [(Double, Int)] = [(0, 100), (100, 0), (37.5, 62), (0.3, 99), (99.9, 0), (104, 0), (-2, 100)]
        for (used, left) in cases {
            try expectEqual(parse(usageJSON(fiveHour: .used(used, resetsAt: nil)))?.fiveHour?.remainingPercent,
                            left, "已用 \(used)")
        }
    }

    static func nullWindowsHidden() throws {
        let s = parse(usageJSON(fiveHour: .used(nil, resetsAt: "2027-01-15T08:00:00Z"), sevenDay: .null))
        try expect(s != nil, "有已知顶层字段，格式应有效")
        try expect(s?.fiveHour == nil, "utilization 为 null 的窗口不应显示")
        try expect(s?.sevenDay == nil, "窗口为 null 时不应显示")
        let missing = parse(usageJSON(fiveHour: nil, sevenDay: .used(10, resetsAt: nil)))
        try expect(missing?.fiveHour == nil, "缺失的窗口不应显示")
        try expectEqual(missing?.sevenDay?.remainingPercent, 90)
        let wrongType = parse(#"{"five_hour":{"utilization":"12","resets_at":null},"seven_day":{"utilization":true}}"#)
        try expect(wrongType?.fiveHour == nil && wrongType?.sevenDay == nil, "utilization 不是数字时不显示")
    }

    static func resetTimes() throws {
        let iso = parse(usageJSON(fiveHour: .used(1, resetsAt: "2027-01-15T08:00:00.943648+00:00"),
                                  sevenDay: .used(1, resetsAt: "2027-01-20T17:30:00+08:00")))
        try expectEqual(iso?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        try expectEqual(iso?.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_800_437_400))
        let seconds = parse(#"{"five_hour":{"utilization":5,"resets_at":1800000000}}"#)
        try expectEqual(seconds?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        let none = parse(usageJSON(fiveHour: .used(5, resetsAt: nil), sevenDay: .used(5, resetsAt: "soon")))
        try expect(none?.fiveHour != nil && none?.fiveHour?.resetsAt == nil, "resets_at 为 null 时窗口照常显示")
        try expect(none?.sevenDay != nil && none?.sevenDay?.resetsAt == nil, "resets_at 认不出时窗口照常显示")
    }

    static func unrecognizedFormat() throws {
        for body in ["{}", #"{"error":"x"}"#, "[]", "not json", ""] {
            try expect(parse(body) == nil, "应归为格式无法识别：\(body)")
        }
        for key in ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "limits", "extra_usage"] {
            try expect(parse(#"{"\#(key)":null}"#) != nil, "有 \(key) 时格式应有效")
        }
    }
}
