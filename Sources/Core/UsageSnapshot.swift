// 一次成功获取的额度（spec "额度接口" 的响应字段）。只用于显示，不含任何凭据。
//
// 取 5 小时窗口（five_hour）和覆盖全部模型的周窗口（seven_day）；limits[] 里的 severity 不用，
// 颜色按内置阈值（token-usage 决定 10）。
// 展开账号后显示的详情（ticket 13）：按模型细分的周窗口、超额付费（extra_usage）。
// 窗口怎么显示（剩余、已重置、变灰、颜色）见 UsageReading。

import Foundation

/// 一个额度窗口
struct UsageWindow: Equatable {
    /// 已用百分比（接口原值，0–100）
    let utilization: Double
    /// 重置时间；接口没给时为 nil
    let resetsAt: Date?

    /// 剩余百分比 = 100 − 已用百分比，限制在 0–100。
    /// 有小数时向下取整：宁可少报一点剩余，也不多报（例如已用 0.3% 显示剩余 99%，而不是 100%）。
    var remainingPercent: Int {
        Int(min(100, max(0, (100 - utilization).rounded(.down))))
    }
}

/// 按模型细分的一个周窗口
struct ModelWeeklyWindow: Equatable {
    /// 模型名（scope.model.display_name）；没给时为 nil，界面用通用标题
    let model: String?
    let window: UsageWindow
}

struct UsageSnapshot: Equatable {
    /// 5 小时窗口；utilization 为 null 或缺失时为 nil（不显示）
    let fiveHour: UsageWindow?
    /// 覆盖全部模型的周窗口
    let sevenDay: UsageWindow?
    /// 按模型细分的周窗口（见 modelWeeklyWindows）
    var modelWeekly: [ModelWeeklyWindow] = []
    /// 超额付费；接口没给（或认不出）时为 nil，不显示
    var extraUsage: ExtraUsage? = nil
    /// 这次数据的获取时间
    let fetchedAt: Date

    /// 只要有其中任意一个，就认为响应格式有效
    static let knownTopLevelKeys = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus",
                                    "limits", "extra_usage"]

    init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, modelWeekly: [ModelWeeklyWindow] = [],
         extraUsage: ExtraUsage? = nil, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.modelWeekly = modelWeekly
        self.extraUsage = extraUsage
        self.fetchedAt = fetchedAt
    }

    /// 解析响应体；不是 JSON 对象、或一个已知的顶层字段都没有时返回 nil（格式无法识别）
    init?(json data: Data, fetchedAt: Date) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Self.knownTopLevelKeys.contains(where: { root[$0] != nil }) else { return nil }
        let limits = Self.limitRows(root["limits"])
        self.init(fiveHour: Self.window(root["five_hour"]),
                  sevenDay: Self.window(root["seven_day"]),
                  modelWeekly: limits.isEmpty ? Self.topLevelModelWindows(root) : Self.modelWeeklyWindows(limits),
                  extraUsage: ExtraUsage(json: root["extra_usage"]),
                  fetchedAt: fetchedAt)
    }

    /// 没有 limits[]（缺失、null、空数组）时的回退：顶层的 seven_day_sonnet、seven_day_opus（有数字才显示）
    static func topLevelModelWindows(_ root: [String: Any]) -> [ModelWeeklyWindow] {
        [("Sonnet", "seven_day_sonnet"), ("Opus", "seven_day_opus")].compactMap { model, key in
            window(root[key]).map { ModelWeeklyWindow(model: model, window: $0) }
        }
    }

    /// 按模型细分的周窗口：limits[] 中 kind 为 weekly_scoped 的每一行各一个，按原顺序。
    /// 剩余 = 100 − percent；percent 不是数字的行不显示。
    static func modelWeeklyWindows(_ limits: [[String: Any]]) -> [ModelWeeklyWindow] {
        limits.compactMap { row in
            guard row["kind"] as? String == "weekly_scoped", let percent = number(row["percent"]) else { return nil }
            let model = ((row["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            return ModelWeeklyWindow(model: model, window: UsageWindow(utilization: percent,
                                                                        resetsAt: date(row["resets_at"])))
        }
    }

    /// limits[] 的各行（不是数组、或某行不是对象时跳过）
    static func limitRows(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// {utilization, resets_at}；utilization 不是数字（null、缺失、类型不对）时整个窗口不显示
    private static func window(_ value: Any?) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let utilization = number(object["utilization"]) else { return nil }
        return UsageWindow(utilization: utilization, resetsAt: date(object["resets_at"]))
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
        return isoFormatter.date(from: trimmed)
    }

    /// 配置好之后只用来解析、不再修改（格式化器在这种用法下线程安全）
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
