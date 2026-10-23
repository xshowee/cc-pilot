// 档案行里的额度：5 小时窗口和"全部模型"周窗口的剩余百分比（明确标注"剩余"）与重置时间（本地时区），
// 这次数据是几分钟前获取的，以及最近一次刷新失败的原因（ticket 12）。
// 没有数字的窗口（utilization 为 null）不显示；怎么显示每个窗口由 App 核心的 UsageReading 决定。

import SwiftUI

struct UsageSummaryView: View {
    let usage: AccountUsage
    /// 档案行已显示的登录状态；失败原因是同一个状态时不重复提示
    var loginStatus: LoginStatus?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let reading = usage.fiveHour(now: now) {
                UsageWindowLine(title: String(localized: "5-hour"), reading: reading,
                                resetsAt: usage.snapshot?.fiveHour?.resetsAt, now: now)
            }
            if let reading = usage.sevenDay(now: now) {
                UsageWindowLine(title: String(localized: "Weekly (all models)"), reading: reading,
                                resetsAt: usage.snapshot?.sevenDay?.resetsAt, now: now)
            }
            if let snapshot = usage.snapshot {
                Text(verbatim: fetchedText(snapshot.fetchedAt))
                    .foregroundColor(.secondary)
            }
            if let problem = usage.problem, let text = problemText(problem) {
                Label {
                    Text(verbatim: text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .foregroundColor(.orange)
            }
        }
        .font(.caption)
    }

    private func fetchedText(_ fetchedAt: Date) -> String {
        let minutes = UsageDisplay.minutesSince(fetchedAt, now: now)
        return minutes == 0
            ? String(localized: "Updated just now")
            : String(localized: "Updated \(minutes) min ago")
    }

    /// 失败原因的提示；不需要提示时为 nil
    private func problemText(_ problem: UsageProblem) -> String? {
        switch problem {
        case .login(let status):
            // 没发请求（与行里的登录状态相同）时不重复；401 时行里还是"已登录"，要说明
            guard status != loginStatus, let title = LoginStatusText.title(status) else { return nil }
            return [title, LoginStatusText.hint(status)].compactMap { $0 }.joined(separator: " — ")
        case .rateLimited:
            guard let wait = usage.waitRemaining(now: now) else { return nil }
            return String(localized: "Too many requests. Try again in \(UsageDisplay.waitMinutes(wait)) min.")
        case .httpStatus(let code):
            return String(localized: "The server returned an error (HTTP \(code)).")
        case .networkFailure:
            return usage.snapshot == nil
                ? String(localized: "Couldn’t reach the server.")
                : String(localized: "Couldn’t reach the server. Showing the last data fetched.")
        case .unrecognizedFormat:
            return String(localized: "The usage API may have changed. Please update cc-pilot.")
        }
    }
}

/// 一个额度窗口的一行：标题、剩余（或"已重置，待刷新""—"），有数字时附上重置时间（本地时区）。
/// 档案行和展开后的详情（ticket 13）共用。宽度不足时放不下的那段整段折到下一行，不截断（ticket 23）。
struct UsageWindowLine: View {
    let title: String
    let reading: UsageReading
    let resetsAt: Date?
    let now: Date

    var body: some View {
        WrappingHStack(spacing: 4) {
            Text(verbatim: title)
                .foregroundColor(.secondary)
            UsageReadingText(reading: reading)
            if case .remaining = reading, let resetsAt {
                Text("· resets \(UsageDisplay.resetTime(resetsAt, now: now))")
                    .foregroundColor(.secondary)
            }
        }
    }
}
