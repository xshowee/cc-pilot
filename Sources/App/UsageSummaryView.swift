// 档案行里的额度：5 小时窗口和"全部模型"周窗口的剩余百分比（明确标注"剩余"）与重置时间（本地时区），
// 以及这次数据是几分钟前获取的。没有数字的窗口（utilization 为 null）不显示。

import SwiftUI

struct UsageSummaryView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        // 每 30 秒重算一次"几分钟前"和"当天/非当天"的重置时间写法
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 1) {
                if let window = snapshot.fiveHour {
                    line(String(localized: "5-hour"), window, now: context.date)
                }
                if let window = snapshot.sevenDay {
                    line(String(localized: "Weekly (all models)"), window, now: context.date)
                }
                Text(verbatim: fetchedText(now: context.date))
                    .foregroundColor(.secondary)
            }
            .font(.caption)
        }
    }

    private func line(_ title: String, _ window: UsageWindow, now: Date) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: title)
                .foregroundColor(.secondary)
            Text("\(window.remainingPercent)% left")
                .fontWeight(.semibold)
                .monospacedDigit()
            if let resetsAt = window.resetsAt {
                Text("· resets \(UsageDisplay.resetTime(resetsAt, now: now))")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func fetchedText(now: Date) -> String {
        let minutes = UsageDisplay.minutesSince(snapshot.fetchedAt, now: now)
        return minutes == 0
            ? String(localized: "Updated just now")
            : String(localized: "Updated \(minutes) min ago")
    }
}
