// ticket 11：额度的显示。重置时间按本地时区显示；获取时间显示为"N 分钟前"。

import Foundation

final class UsageDisplayChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("重置时间按本地时区显示：当天只显示时刻，不是当天加上日期", resetTimeInLocalTimeZone),
            Check("获取时间显示为几分钟前（不足一分钟算 0）", minutesSinceFetch),
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

    static func minutesSinceFetch() throws {
        let cases: [(TimeInterval, Int)] = [(0, 0), (59, 0), (60, 1), (125, 2), (3600, 60), (-30, 0)]
        for (elapsed, minutes) in cases {
            try expectEqual(UsageDisplay.minutesSince(fixedNow, now: fixedNow.addingTimeInterval(elapsed)),
                            minutes, "过了 \(elapsed) 秒")
        }
    }
}
