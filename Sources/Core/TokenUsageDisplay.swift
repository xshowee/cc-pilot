// 统计面板（token-usage ticket 07）里的数字写法。界面文字（"自 …""… 后重置"等）由 Sources/App 本地化，
// 这里只算数和格式化：
//   Token 数   不足一千写整数；K、M 一位小数，B 两位小数（与原型一致）。按四舍五入后的值选单位，
//              999 950 写 1.0M 而不是 1000.0K。Token 用量为 0 时照常写 0。
//   占比       四舍五入到整数百分比；大于 0 但不足 1% 写 "<1%"，不写成 0%；总数为 0 时写 0%。

import Foundation

enum TokenUsageDisplay {
    /// Token 数的简写（12.3K、1.0M、2.35B）
    static func compact(_ value: Int) -> String {
        guard value >= 1000 else { return String(value) }
        // （单位，换算到这个单位的除数，小数位数），从小到大
        let units: [(String, Double, Int)] = [("K", 1e3, 1), ("M", 1e6, 1), ("B", 1e9, 2)]
        for (index, (suffix, divisor, digits)) in units.enumerated() {
            let scale = pow(10, Double(digits))
            let rounded = (Double(value) / divisor * scale).rounded() / scale
            if rounded < 1000 || index == units.count - 1 {
                return String(format: "%.\(digits)f", rounded) + suffix
            }
        }
        return String(value)
    }

    /// part 占 total 的百分比（"13%""<1%"）
    static func share(_ part: Int, of total: Int) -> String {
        guard total > 0, part > 0 else { return "0%" }
        let fraction = Double(part) / Double(total)
        return fraction < 0.01 ? "<1%" : "\(Int((fraction * 100).rounded()))%"
    }

    /// 起算点（"自 …"），按本地时区：和 now 同一天只写时刻（刚清空过），同一年写月日，往年加上年份。
    /// 写法跟随 locale（zh_CN "9月24日"，en_GB "3 Jan"）
    static func origin(_ date: Date, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let template = calendar.isDate(date, inSameDayAs: now) ? "jjmm"
            : calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMd" : "yMMMd"
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// 离 resetsAt 还有多久；已经到点（或过了）时为 nil
    static func countdown(to resetsAt: Date, now: Date) -> ResetCountdown? {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes >= 1440 { return .daysHours(minutes / 1440, minutes % 1440 / 60) }
        if minutes >= 60 { return .hoursMinutes(minutes / 60, minutes % 60) }
        return .minutes(minutes)
    }
}

/// 重置倒计时：按整分钟向上取（还剩 30 秒算 1 分钟，宁可多说不少说），只保留最大的两个单位
enum ResetCountdown: Equatable {
    case daysHours(Int, Int)
    case hoursMinutes(Int, Int)
    case minutes(Int)
}
