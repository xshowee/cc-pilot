// Kimi Code 套餐有效期（KimiExpiry.swift，ADR 0007 2026-11-11 补充）：用户填的日历日期，当天仍有效；
// 卡片按剩余天数显示：7 天以上普通、1–7 天快到期、当天最后一天、过了已过期。按本机日历算，不涉及时区换算。

import Foundation

final class KimiExpiryChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("日期存成 yyyy-MM-dd，不合法、不存在的日期读不进来", parsing),
            Check("剩余天数：7 天以上普通、1–7 天快到期、当天最后一天、之后已过期", status),
            Check("一天里的任何时刻都算同一天；按传入的日历算", timeOfDay),
        ]
    }

    static func date(_ text: String) throws -> KimiExpiryDate { try unwrap(KimiExpiryDate(string: text), text) }

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// zone 时区里这一天的 hour:minute
    static func moment(_ text: String, _ hour: Int, _ minute: Int = 0, zone: String = "Asia/Shanghai") throws -> Date {
        let day = try date(text)
        return try unwrap(calendar(zone).date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                                   hour: hour, minute: minute)))
    }

    static func parsing() throws {
        let expiry = try date("2027-02-11")
        try expectEqual([expiry.year, expiry.month, expiry.day], [2027, 2, 11])
        try expectEqual(expiry.string, "2027-02-11")
        try expectEqual(try date("2028-02-29").string, "2028-02-29", "闰年")
        for bad in ["", "2027-2-11", "2027-02-30", "2027-13-01", "2027-00-10", "2027-02-00", "27-02-11",
                    "2027-02-11T00:00:00Z", "2027/02/11", "abcd-ef-gh", "2027-02-11-01", "2027--2-11"] {
            try expect(KimiExpiryDate(string: bad) == nil, "不应读进来：\(bad)")
        }
        let shanghai = calendar("Asia/Shanghai")
        try expectEqual(KimiExpiryDate(date: try moment("2027-02-11", 23, 59), calendar: shanghai), expiry)
    }

    static func status() throws {
        let expiry = try date("2027-02-11")
        let shanghai = calendar("Asia/Shanghai")
        func at(_ day: String) throws -> KimiExpiryStatus {
            KimiExpiryStatus.of(expiry, now: try moment(day, 12), calendar: shanghai)
        }
        try expectEqual(try at("2026-11-11"), .valid(until: expiry))
        try expectEqual(try at("2027-02-03"), .valid(until: expiry), "还剩 8 天")
        try expectEqual(try at("2027-02-04"), .soon(days: 7, until: expiry), "还剩 7 天")
        try expectEqual(try at("2027-02-10"), .soon(days: 1, until: expiry))
        try expectEqual(try at("2027-02-11"), .lastDay, "当天仍有效")
        try expectEqual(try at("2027-02-12"), .expired(on: expiry))
        try expectEqual(try at("2028-01-01"), .expired(on: expiry))
        // 跨月、跨闰日
        try expectEqual(KimiExpiryStatus.of(try date("2028-03-01"), now: try moment("2028-02-27", 9), calendar: shanghai),
                        .soon(days: 3, until: try date("2028-03-01")))
    }

    static func timeOfDay() throws {
        let expiry = try date("2027-02-11")
        let shanghai = calendar("Asia/Shanghai")
        try expectEqual(KimiExpiryStatus.of(expiry, now: try moment("2027-02-11", 0, 0), calendar: shanghai), .lastDay)
        try expectEqual(KimiExpiryStatus.of(expiry, now: try moment("2027-02-11", 23, 59), calendar: shanghai), .lastDay)
        try expectEqual(KimiExpiryStatus.of(expiry, now: try moment("2027-02-12", 0, 0), calendar: shanghai),
                        .expired(on: expiry))
        // 同一时刻，在纽约还是 2 月 10 日：按传入的日历算
        let instant = try moment("2027-02-11", 8)   // 上海 08:00 = 纽约前一天 19:00
        try expectEqual(KimiExpiryStatus.of(expiry, now: instant, calendar: calendar("America/New_York")),
                        .soon(days: 1, until: expiry))
    }
}
