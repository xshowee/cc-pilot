// token-usage ticket 07：统计面板里的数字写法（Token 数 K/M/B、占比、重置倒计时、起算点）。

import Foundation

final class TokenUsageDisplayChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("Token 数：不足一千写整数，K / M 一位小数，B 两位小数；0 照常写 0", compactTokens),
            Check("占比：四舍五入到整数，大于 0 不足 1% 写 <1%，总数为 0 写 0%", shares),
            Check("重置倒计时：按整分钟向上取，只写最大的两个单位；已经到点时没有倒计时", countdown),
            Check("起算点：当天只写时刻，今年写月日，往年加上年份（本地时区）", originDate),
            Check("历史悬停提示的时间：24 小时写这一格的时段，30 天写日期和星期（本地时区）", historySlot),
        ]
    }

    static func compactTokens() throws {
        let cases: [(Int, String)] = [
            (0, "0"), (7, "7"), (999, "999"), (1_000, "1.0K"), (12_345, "12.3K"),
            (999_949, "999.9K"), (999_950, "1.0M"),           // 进位后换单位，不写 1000.0K
            (1_250_000, "1.3M"), (210_000_000, "210.0M"),
            (999_950_000, "1.00B"), (2_345_678_901, "2.35B"),
        ]
        for (value, text) in cases {
            try expectEqual(TokenUsageDisplay.compact(value), text, "\(value)")
        }
    }

    static func shares() throws {
        let cases: [(Int, Int, String)] = [
            (0, 0, "0%"), (0, 500, "0%"), (1, 1000, "<1%"), (9, 1000, "<1%"), (10, 1000, "1%"),
            (125, 1000, "13%"), (937, 1000, "94%"), (1000, 1000, "100%"),
        ]
        for (part, total, text) in cases {
            try expectEqual(TokenUsageDisplay.share(part, of: total), text, "\(part)/\(total)")
        }
    }

    static func countdown() throws {
        let now = fixedNow
        let cases: [(TimeInterval, ResetCountdown?)] = [
            (30, .minutes(1)), (41 * 60, .minutes(41)), (59 * 60 + 1, .hoursMinutes(1, 0)),
            (2 * 3600 + 13 * 60, .hoursMinutes(2, 13)), (23 * 3600 + 59 * 60 + 30, .daysHours(1, 0)),
            (3 * 86400 + 5 * 3600 + 20 * 60, .daysHours(3, 5)),
            (0, nil), (-60, nil),
        ]
        for (left, expected) in cases {
            try expectEqual(TokenUsageDisplay.countdown(to: now + left, now: now), expected, "还剩 \(left) 秒")
        }
    }

    static func originDate() throws {
        // fixedNow 是 2027-01-15 08:00 UTC，即上海 16:00
        let utc = TimeZone(identifier: "UTC")!, shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let zh = Locale(identifier: "zh_CN"), gb = Locale(identifier: "en_GB")
        let earlierToday = fixedNow - 2 * 3600                                  // 06:00 UTC
        try expectEqual(TokenUsageDisplay.origin(earlierToday, now: fixedNow, timeZone: utc, locale: gb), "06:00")
        let thisYear = TranscriptLine.parseTimestamp("2027-01-03T10:00:00Z")!
        try expectEqual(TokenUsageDisplay.origin(thisYear, now: fixedNow, timeZone: shanghai, locale: zh), "1月3日")
        try expectEqual(TokenUsageDisplay.origin(thisYear, now: fixedNow, timeZone: utc, locale: gb), "3 Jan")
        let lastYear = TranscriptLine.parseTimestamp("2026-09-24T10:00:00Z")!
        try expectEqual(TokenUsageDisplay.origin(lastYear, now: fixedNow, timeZone: shanghai, locale: zh),
                        "2026年9月24日")
    }

    static func historySlot() throws {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let zh = Locale(identifier: "zh_CN"), gb = Locale(identifier: "en_GB")
        // 2026-10-24 14:00（上海，周六）
        let start = Date(timeIntervalSince1970: 1_792_821_600)
        try expectEqual(TokenUsageDisplay.historySlot(start, range: .hours, timeZone: shanghai, locale: zh),
                        "14:00–15:00")
        try expectEqual(TokenUsageDisplay.historySlot(start, range: .hours, timeZone: shanghai, locale: gb),
                        "14:00–15:00")
        // 跨午夜的最后一格
        let late = start.addingTimeInterval(10 * 3600)
        try expectEqual(TokenUsageDisplay.historySlot(late, range: .hours, timeZone: shanghai, locale: zh),
                        "00:00–01:00")
        try expectEqual(TokenUsageDisplay.historySlot(start, range: .days, timeZone: shanghai, locale: zh),
                        "10月24日 周六")
        try expectEqual(TokenUsageDisplay.historySlot(start, range: .days, timeZone: shanghai, locale: gb),
                        "Sat 24 Oct")
    }
}
