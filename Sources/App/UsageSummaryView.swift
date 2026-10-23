// 档案行里的一项额度信息（ticket 19 起由 ProfileRow 按 App 核心的 ProfileRowPart.order 逐项显示）：
// 5 小时窗口和"全部模型"周窗口的剩余百分比（明确标注"剩余"）与重置时间（本地时区），
// 这次数据是几分钟前获取的，以及最近一次刷新失败的原因（ticket 12）；展开后的详情交给 UsageDetailsView。
// 没有数字的窗口（utilization 为 null）不显示；怎么显示每个窗口由 App 核心的 UsageReading 决定。

import SwiftUI

struct UsageSummaryView: View {
    let usage: AccountUsage
    let part: ProfileRowPart
    /// 档案行已显示的登录状态；失败原因是同一个状态时不重复提示
    var loginStatus: LoginStatus?
    let now: Date

    var body: some View {
        switch part {
        case .mainWindows:
            if let reading = usage.fiveHour(now: now) {
                UsageWindowLine(title: String(localized: "5-hour"), reading: reading,
                                resetsAt: usage.snapshot?.fiveHour?.resetsAt, now: now)
            }
            if let reading = usage.sevenDay(now: now) {
                UsageWindowLine(title: String(localized: "Weekly (all models)"), reading: reading,
                                resetsAt: usage.snapshot?.sevenDay?.resetsAt, now: now)
            }
        case .modelWeekly, .extraUsage:
            UsageDetailsView(usage: usage, part: part, now: now)
        case .fetchedAt:
            if let snapshot = usage.snapshot {
                Text(verbatim: fetchedText(snapshot.fetchedAt))
                    .foregroundColor(.secondary)
            }
        case .problem:
            if let problem = usage.problem, let text = problemText(problem) {
                Label {
                    Text(verbatim: text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .foregroundColor(StatusColor.orange)
            }
        case .sameAccount:
            // 不是额度信息，由 ProfileRow 显示
            EmptyView()
        }
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

/// 一个额度窗口：左边标题，有数字时附上重置时间（本地时区）；右边剩余（或"已重置，待刷新""—"）；
/// 有数字时下方是剩余比例的进度条。档案行和展开后的详情（ticket 13）共用。
/// 一行放不下时改为逐段折行，放不下的那段整段折到下一行，不截断（ticket 23）。
struct UsageWindowLine: View {
    let title: String
    let reading: UsageReading
    let resetsAt: Date?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    titleText
                    resetText
                    Spacer(minLength: 8)
                    readingText
                }
                WrappingHStack(spacing: 4) {
                    titleText
                    resetText
                    readingText
                }
            }
            if case .remaining(let percent, let tint) = reading {
                // 过期灰本身很深（为了菜单栏上的文字可读，ticket 26），进度条用淡一些的，不比新数据还显眼
                UsageMeter(fraction: Double(percent) / 100,
                           color: tint == .stale ? tint.color?.opacity(0.45) : tint.color)
            }
        }
    }

    private var titleText: some View {
        Text(verbatim: title)
            .foregroundColor(.secondary)
    }

    @ViewBuilder private var resetText: some View {
        if case .remaining = reading, let resetsAt {
            Text("· resets \(UsageDisplay.resetTime(resetsAt, now: now))")
                .foregroundColor(.secondary.opacity(0.8))
        }
    }

    private var readingText: some View {
        UsageReadingText(reading: reading)
            .font(.callout)
    }
}
