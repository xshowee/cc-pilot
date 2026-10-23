// 超额付费（额度接口的 extra_usage，ticket 13）：是否开启、月度上限、已使用金额。只用于显示。
//
// 金额以该币种的最小单位给出（例如美元是美分），按币种换算成常用单位；币种没给或认不出时不猜，
// 界面显示"—"。过期变灰见 AccountUsage.extraUsage(now:)。

import Foundation

/// 一笔金额（接口原值，以该币种的最小单位表示）
struct CreditAmount: Equatable {
    let minorUnits: Double
    /// ISO 4217 币种代码（接口原值）；没给时为 nil
    let currency: String?

    /// 规范化的币种代码；没给或认不出时为 nil
    var currencyCode: String? {
        guard let code = currency?.uppercased(),
              Locale.Currency.isoCurrencies.contains(where: { $0.identifier == code }) else { return nil }
        return code
    }

    /// 换算成常用单位的金额（例如 1234 美分 → 12.34 美元）；币种没给或认不出时为 nil
    var majorUnits: Decimal? {
        guard let code = currencyCode else { return nil }
        var value = Decimal(minorUnits)
        for _ in 0..<Self.fractionDigits(code) { value /= 10 }
        return value
    }

    /// 币种的最小单位位数（USD 2、JPY 0、KWD 3），取自系统的币种数据；按币种缓存（界面每次重绘都会用到）
    private static func fractionDigits(_ code: String) -> Int {
        fractionDigitsLock.lock()
        defer { fractionDigitsLock.unlock() }
        if let digits = fractionDigitsCache[code] { return digits }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        fractionDigitsCache[code] = formatter.maximumFractionDigits
        return formatter.maximumFractionDigits
    }

    private static let fractionDigitsLock = NSLock()
    nonisolated(unsafe) private static var fractionDigitsCache: [String: Int] = [:]  // 由 fractionDigitsLock 保护
}

/// 超额付费的状态
enum ExtraUsage: Equatable {
    /// 没有开启
    case disabled
    /// 已开启。monthlyLimit 为 nil 表示不设上限；used 为 nil 表示接口没给出已使用金额
    case enabled(monthlyLimit: CreditAmount?, used: CreditAmount?)

    /// 解析 extra_usage；不是对象、或 is_enabled 不是布尔值时为 nil（不显示）
    init?(json value: Any?) {
        guard let object = value as? [String: Any],
              let flag = object["is_enabled"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
        guard flag.boolValue else { self = .disabled; return }
        let currency = object["currency"] as? String
        func amount(_ key: String) -> CreditAmount? {
            UsageSnapshot.number(object[key]).map { CreditAmount(minorUnits: $0, currency: currency) }
        }
        self = .enabled(monthlyLimit: amount("monthly_limit"), used: amount("used_credits"))
    }
}

/// 超额付费此刻怎么显示：tint 只会是 plain（不着色，接口没有给它 severity）或 stale（变灰）
struct ExtraUsageReading: Equatable {
    let usage: ExtraUsage
    let tint: UsageTint
}
