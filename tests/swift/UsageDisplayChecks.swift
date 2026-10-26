// ticket 11：额度的显示。重置时间按本地时区显示；获取时间显示为"N 分钟前""N 小时 M 分钟前"等。

import Foundation

final class UsageDisplayChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("重置时间按本地时区显示：当天只显示时刻，不是当天加上日期", resetTimeInLocalTimeZone),
            Check("获取时间：向下取整，保留最大的两个单位，第二个单位是 0 时省掉", fetchAge),
            Check("频率限制还要等几分钟：向上取整，至少 1 分钟（ticket 12）", waitMinutes),
        ]
    }

    static let utc = TimeZone(identifier: "UTC")!
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static let gb = Locale(identifier: "en_GB")

    static func resetTimeInLocalTimeZone() throws {
        // fixedNow 是 2027-01-15 08:00 UTC，即上海 16:00
        let sameDay = fixedNow.addingTimeInterval(2 * 3600)       // 10:00 UTC / 18:00 上海
        try expectEqual(UsageDisplay.resetTime(sameDay, now: fixedNow, timeZone: utc, locale: gb), "10:00")
        try expectEqual(UsageDisplay.resetTime(sameDay, now: fixedNow, timeZone: shanghai, locale: gb), "18:00")

        // 20:00 UTC：在 UTC 还是当天，在上海已经是第二天 04:00
        let evening = fixedNow.addingTimeInterval(12 * 3600)
        try expectEqual(UsageDisplay.resetTime(evening, now: fixedNow, timeZone: utc, locale: gb), "20:00")
        let next = UsageDisplay.resetTime(evening, now: fixedNow, timeZone: shanghai, locale: gb)
        try expect(next.contains("16 Jan") && next.contains("04:00"), "上海时区应显示第二天：\(next)")

        // 几天后：2027-01-20 09:30 UTC
        let later = Date(timeIntervalSince1970: 1_800_437_400)
        let text = UsageDisplay.resetTime(later, now: fixedNow, timeZone: utc, locale: gb)
        try expect(text.contains("20 Jan") && text.contains("09:30"), "应带日期：\(text)")
    }

    static func fetchAge() throws {
        let cases: [(TimeInterval, FetchAge)] = [
            (0, .justNow), (59, .justNow), (-30, .justNow),
            (60, .minutes(1)), (125, .minutes(2)), (3599, .minutes(59)),
            (3600, .hours(1)), (209 * 60 + 59, .hoursMinutes(3, 29)), (86399, .hoursMinutes(23, 59)),
            (86400, .days(1)), (2 * 86400 + 3 * 3600 + 3599, .daysHours(2, 3)),
        ]
        for (elapsed, age) in cases {
            try expectEqual(UsageDisplay.fetchAge(fixedNow, now: fixedNow.addingTimeInterval(elapsed)),
                            age, "过了 \(elapsed) 秒")
        }
    }

    static func waitMinutes() throws {
        let cases: [(TimeInterval, Int)] = [(1, 1), (59, 1), (60, 1), (61, 2), (299.5, 5), (3600, 60)]
        for (seconds, minutes) in cases {
            try expectEqual(UsageDisplay.waitMinutes(seconds), minutes, "还要等 \(seconds) 秒")
        }
    }
}
