// 额度显示用的时间格式（界面文字里的"剩余""N 分钟前"等由 Sources/App 本地化，这里只算数和格式化时间）。

import Foundation

enum UsageDisplay {
    /// 重置时间，按本地时区：和 now 在同一天（按该时区）只显示时刻，否则加上月、日。
    /// 时刻与日期的写法跟随 locale（例如 en_GB "20 Jan, 09:30"，zh_CN "1月20日 09:30"）。
    static func resetTime(_ date: Date, now: Date, timeZone: TimeZone = .current,
                          locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(date, inSameDayAs: now) ? "jjmm" : "MMMdjjmm")
        return formatter.string(from: date)
    }

    /// 从获取时间到 now 过了几分钟（向下取整，不会是负数）
    static func minutesSince(_ fetchedAt: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(fetchedAt) / 60))
    }

    /// 频率限制还要等几分钟（AccountUsage.waitRemaining 的秒数）：向上取整，至少 1，宁可多说不少说
    static func waitMinutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded(.up)))
    }

    /// 超额付费的金额，按 locale 带币种符号（例如 en_US "$12.34"）；币种没给或认不出时为 nil（界面显示"—"）
    static func money(_ amount: CreditAmount, locale: Locale = .current) -> String? {
        guard let code = amount.currencyCode, let value = amount.majorUnits else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.string(from: value as NSDecimalNumber)
    }
}
