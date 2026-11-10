// 刷新 Kimi Code 额度（ADR 0007）。与 UsageRefresher、ChatGPTUsageRefresher 并列，但 Kimi Code 只显示额度：
// 没有档案、不能切换、没有实时额度，也不属于 Tool。
//
// 用法（只在用户点"刷新全部"或某张 Kimi Code 卡片的刷新按钮时调用；在后台队列上调用，会阻塞）：
//   KimiUsageRefresher(environment: env).refresh("work", now: Date())   → 交给 UsageBoard.recordReplacing(_:)
// （不是 record(_:)：Kimi Code 只有刷新这一个数据来源，成功的结果直接替换旧数字；5 小时窗口是滚动的，
// 已用比例会下降，合并规则会停在较高的旧数字上。）
// 额度记在与 Claude、ChatGPT 共用的看板里。一个 Kimi Code 账号 = 用户起的名称 + 一个 API key（KimiKeyStore），
// 看板里的键是 account(名称)（"kimi:" 前缀，不会相撞）。响应里没有邮箱、套餐，认不出两个 key 是不是同一个
// Kimi 账号：各显示各的，不合并。删除账号时要 UsageBoard.forget 它（之后可能用同一个名称加另一个 key）。
//
// 接口：GET https://api.kimi.com/coding/v1/usages，头只有 Authorization（Bearer <API key>）和
// User-Agent（如实标明 cc-pilot）。接口没有官方文档，Kimi 团队称它是实验性的；下面的格式是 2026-11-10 实测：
//   {"usage": {...}, "limits": [...],
//    "usages": {"limit_5h": {"used_ratio": 0,      "reset_time": "2026-11-10T07:58:26Z"},
//               "limit_7d": {"used_ratio": 0.1101, "reset_time": "2026-11-11T00:58:26Z"}}}
// 只读 usages.limit_5h / limit_7d：已用百分比 = used_ratio × 100。顶层的 usage、limits[] 没有标明是哪个窗口
// （官方说明里不同套餐含义不同），不读、不猜；没有 usages（或里面两个窗口的键都没有）就是格式无法识别。
// used_ratio 不是数字的窗口不显示。
//
// 状态码：401 → key 被拒绝；429 → 频率限制；其他（含 403，Kimi 这边它的含义没有验证过）原样记录。
// 看板里的失败原因用的是 Claude 的 LoginStatus（共用看板）：
//   没有 key（刷新前刚被删除）→ .denied(.notLoggedIn)
//   读不到 key（钥匙串授权被拒等）→ .denied(.accountUnreadable)
//   401 → .unauthorized(.notLoggedIn)
// 界面上 Kimi Code 卡片用自己的文字显示这几种（KimiCard），不能落到 Claude 的提示上。

import Foundation

struct KimiUsageRefresher: Sendable {
    static let usageEndpoint = URL(string: "https://api.kimi.com/coding/v1/usages")!
    /// 这个名称的 Kimi Code 账号在额度看板里的键
    static func account(_ name: String) -> UsageAccount { UsageAccount(id: "kimi:" + name) }
    /// 单次请求的超时（同 Claude 一侧）
    static let timeout: TimeInterval = UsageRefresher.timeout

    let environment: CoreEnvironment

    init(environment: CoreEnvironment = .live) {
        self.environment = environment
    }

    /// 刷新这个名称的账号
    func refresh(_ name: String, now: Date = Date()) -> UsageRefreshOutcome {
        UsageRefreshOutcome(account: Self.account(name), result: fetch(name, now: now))
    }

    private func fetch(_ name: String, now: Date) -> UsageFetchResult {
        guard environment.kimiKeys.names().contains(name) else { return .denied(.notLoggedIn) }
        guard let key = environment.kimiKeys.read(name) else { return .denied(.accountUnreadable) }

        var request = URLRequest(url: Self.usageEndpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("cc-pilot/" + environment.appVersion, forHTTPHeaderField: "User-Agent")

        guard let response = try? environment.transport.send(request) else { return .networkFailure }
        switch response.status {
        case 200:
            break
        case 401:
            return .unauthorized(.notLoggedIn)
        case 429:
            return .rateLimited(until: UsageRateLimit.retryAt(retryAfter: response.headers["retry-after"], now: now))
        default:
            return .httpStatus(response.status)
        }
        guard let snapshot = KimiUsageResponse.snapshot(json: response.body, fetchedAt: now) else {
            return .unrecognizedFormat
        }
        return .success(snapshot)
    }
}

/// /coding/v1/usages 的响应（只取 usages.limit_5h / limit_7d，见文件头）
enum KimiUsageResponse {
    static let fiveHourKey = "limit_5h"
    static let sevenDayKey = "limit_7d"

    /// 解析响应体。不是 JSON 对象、没有 usages、或 usages 里两个窗口的键都没有时返回 nil（格式无法识别）。
    static func snapshot(json data: Data, fetchedAt: Date) -> UsageSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usages = root["usages"] as? [String: Any],
              usages[fiveHourKey] != nil || usages[sevenDayKey] != nil else { return nil }
        return UsageSnapshot(fiveHour: window(usages[fiveHourKey]), sevenDay: window(usages[sevenDayKey]),
                             fetchedAt: fetchedAt)
    }

    /// {used_ratio, reset_time}；used_ratio 不是数字（null、缺失、类型不对）时整个窗口不显示
    private static func window(_ value: Any?) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let ratio = UsageSnapshot.number(object["used_ratio"]) else { return nil }
        return UsageWindow(utilization: ratio * 100, resetsAt: UsageSnapshot.date(object["reset_time"]))
    }
}
