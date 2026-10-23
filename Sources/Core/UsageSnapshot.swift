// 一次成功获取的额度（spec "额度接口" 的响应字段）。只用于显示，不含任何凭据。
//
// 目前取 5 小时窗口（five_hour）和覆盖全部模型的周窗口（seven_day），以及 limits[] 里它们的严重程度。
// 按模型细分的周窗口、extra_usage 由 ticket 13 在这里补充。
// 窗口怎么显示（剩余、已重置、变灰、颜色）见 UsageReading。

import Foundation

/// 服务端给出的严重程度（limits[] 每一行的 severity）。颜色只来自它，App 不自己设定阈值。
enum UsageSeverity: String, Equatable {
    case normal, warning, critical
}

/// 一个额度窗口
struct UsageWindow: Equatable {
    /// 已用百分比（接口原值，0–100）
    let utilization: Double
    /// 重置时间；接口没给时为 nil
    let resetsAt: Date?
    /// limits[] 中对应那一行的 severity；找不到对应的行（或取值认不出）时为 nil，不着色
    var severity: UsageSeverity? = nil

    /// 剩余百分比 = 100 − 已用百分比，限制在 0–100。
    /// 有小数时向下取整：宁可少报一点剩余，也不多报（例如已用 0.3% 显示剩余 99%，而不是 100%）。
    var remainingPercent: Int {
        Int(min(100, max(0, (100 - utilization).rounded(.down))))
    }
}

struct UsageSnapshot: Equatable {
    /// 5 小时窗口；utilization 为 null 或缺失时为 nil（不显示）
    let fiveHour: UsageWindow?
    /// 覆盖全部模型的周窗口
    let sevenDay: UsageWindow?
    /// 这次数据的获取时间
    let fetchedAt: Date

    /// 只要有其中任意一个，就认为响应格式有效
    static let knownTopLevelKeys = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus",
                                    "limits", "extra_usage"]

    init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }

    /// 解析响应体；不是 JSON 对象、或一个已知的顶层字段都没有时返回 nil（格式无法识别）
    init?(json data: Data, fetchedAt: Date) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Self.knownTopLevelKeys.contains(where: { root[$0] != nil }) else { return nil }
        let limits = Self.limitRows(root["limits"])
        self.init(fiveHour: Self.window(root["five_hour"], severity: Self.severity(of: "session", in: limits)),
                  sevenDay: Self.window(root["seven_day"], severity: Self.severity(of: "weekly_all", in: limits)),
                  fetchedAt: fetchedAt)
    }

    /// limits[] 的各行（不是数组、或某行不是对象时跳过）
    static func limitRows(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// limits[] 中第一个 kind 等于给定值的行的 severity。
    /// 对应关系：5 小时窗口 ↔ session，"全部模型"周窗口 ↔ weekly_all。
    static func severity(of kind: String, in rows: [[String: Any]]) -> UsageSeverity? {
        rows.first { $0["kind"] as? String == kind }.flatMap(severity)
    }

    /// 一行的 severity；不是认得的字符串时为 nil
    static func severity(_ row: [String: Any]) -> UsageSeverity? {
        (row["severity"] as? String).flatMap(UsageSeverity.init(rawValue:))
    }

    /// {utilization, resets_at}；utilization 不是数字（null、缺失、类型不对）时整个窗口不显示
    private static func window(_ value: Any?, severity: UsageSeverity?) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let utilization = number(object["utilization"]) else { return nil }
        return UsageWindow(utilization: utilization, resetsAt: date(object["resets_at"]), severity: severity)
    }

    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// ISO 时间（可带任意位数的小数秒，如 2025-10-23T18:59:59.943648+00:00），或以秒为单位的时间戳
    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        // ISO8601DateFormatter 不认识超过 3 位的小数秒；重置时间不需要亚秒精度，直接去掉
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
