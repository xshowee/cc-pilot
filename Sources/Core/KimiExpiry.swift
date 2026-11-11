// Kimi Code 账号的套餐有效期（ADR 0007，2026-11-11 补充）：用户自己填，cc-pilot 不请求。
// kimi.com 订阅页上的有效期只有网页登录态拿得到（2026-11-11 实测：API key 能用的 /coding/v1/usages、models、me
// 都没有到期时间；www.kimi.com/api/... 不认 API key），而 ADR 0007 不读网页登录凭据，所以让用户照着订阅页填。
// 有效期是一个日历日期（订阅页写"Valid until: 2027-02-11"），当天仍有效，按本机日历算还剩几天，不涉及时区换算。
// 卡片副标题按剩余天数显示（KimiExpiryStatus）；App 不发系统通知（NoNotificationChecks），快到期只靠颜色提示。
// 按账号名称存在 UserDefaults（App 界面层，KimiModel），删除账号时一起删。

import Foundation

/// 一个日历日期（年月日），存成 "yyyy-MM-dd"
struct KimiExpiryDate: Equatable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    /// 不是合法的 "yyyy-MM-dd" 时为 nil（含 2 月 30 日这类不存在的日期）
    init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        guard Self.isValid(year: year, month: month, day: day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// 这个时刻在 calendar 里是哪一天
    init(date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    private init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    var string: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// 这一天在 calendar 里的零点（日期选择器用）
    func date(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func isValid(year: Int, month: Int, day: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard (1...12).contains(month), day >= 1,
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        return calendar.component(.day, from: date) == day && calendar.component(.month, from: date) == month
    }
}

/// 卡片上怎么显示有效期
enum KimiExpiryStatus: Equatable {
    /// 还剩 7 天以上：普通颜色
    case valid(until: KimiExpiryDate)
    /// 还剩 1–7 天：琥珀色
    case soon(days: Int, until: KimiExpiryDate)
    /// 今天是最后一天：琥珀色
    case lastDay
    /// 已经过了：红色
    case expired(on: KimiExpiryDate)

    /// 剩余天数在这以内算快到期
    static let soonDays = 7

    static func of(_ expiry: KimiExpiryDate, now: Date, calendar: Calendar = .current) -> KimiExpiryStatus {
        let today = calendar.startOfDay(for: now)
        guard let end = expiry.date(in: calendar).map(calendar.startOfDay),
              let days = calendar.dateComponents([.day], from: today, to: end).day else { return .valid(until: expiry) }
        if days < 0 { return .expired(on: expiry) }
        if days == 0 { return .lastDay }
        if days <= soonDays { return .soon(days: days, until: expiry) }
        return .valid(until: expiry)
    }
}
