// 频率限制（spec "额度接口"）：收到 429 或 403 时，在 retry-after 规定的时间内不再请求这个账号；
// 没有 retry-after（或认不出）时等 5 分钟；无论哪种，最长不超过 1 小时。
// 等待期间由 UsageBoard 记着（AccountUsage.retryAt），界面据此禁用刷新按钮、显示还要等多久。

import Foundation

enum UsageRateLimit {
    /// 没有 retry-after 时的等待时间
    static let defaultWait: TimeInterval = 5 * 60
    /// 最长等待时间
    static let maxWait: TimeInterval = 60 * 60

    /// 下一次允许请求的时间。retryAfter 是响应头原文：秒数，或 HTTP 日期（如 "Wed, 21 Oct 2026 07:28:00 GMT"）。
    static func retryAt(retryAfter: String?, now: Date) -> Date {
        let wait = retryAfter.flatMap { seconds($0, now: now) } ?? defaultWait
        return now.addingTimeInterval(min(maxWait, max(0, wait)))
    }

    private static func seconds(_ value: String, now: Date) -> TimeInterval? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(text), seconds.isFinite { return seconds }
        return httpDateFormatter.date(from: text).map { $0.timeIntervalSince(now) }
    }

    /// HTTP 日期（RFC 9110 的 IMF-fixdate）。配置好之后只用来解析、不再修改
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
