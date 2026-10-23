// 展开账号后显示的额度详情（ticket 13）：按模型细分的各个周窗口（剩余、重置时间、颜色），
// 以及超额付费（未开启；或月度上限、已使用金额）。
// 过期变灰、已重置、着色都由 App 核心（AccountUsage.modelWeekly / extraUsage）决定，这里只选文字。

import SwiftUI

struct UsageDetailsView: View {
    let usage: AccountUsage
    let now: Date

    /// 有没有可展开的内容（没有时不显示展开按钮）
    static func hasDetails(_ usage: AccountUsage?, now: Date) -> Bool {
        guard let usage else { return false }
        return !usage.modelWeekly(now: now).isEmpty || usage.extraUsage(now: now) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(usage.modelWeekly(now: now).enumerated()), id: \.offset) { _, window in
                UsageWindowLine(title: title(window.model), reading: window.reading,
                                resetsAt: window.resetsAt, now: now)
            }
            if let extra = usage.extraUsage(now: now) {
                extraUsage(extra)
            }
        }
        .font(.caption)
    }

    private func title(_ model: String?) -> String {
        model.map { String(localized: "Weekly (\($0))") } ?? String(localized: "Weekly (other model)")
    }

    private func extraUsage(_ extra: ExtraUsageReading) -> some View {
        HStack(spacing: 4) {
            Text("Extra usage")
                .foregroundColor(.secondary)
            extraUsageText(extra.usage)
                .monospacedDigit()
                .foregroundColor(extra.tint.color)
        }
    }

    private func extraUsageText(_ usage: ExtraUsage) -> Text {
        switch usage {
        case .disabled:
            return Text("Not enabled")
        case .enabled(let monthlyLimit, let used):
            let usedText = money(used)
            guard let monthlyLimit else { return Text("\(usedText) used · no limit") }
            return Text("\(usedText) used · limit \(money(monthlyLimit))")
        }
    }

    /// 金额；没给出、或币种认不出时显示"—"（不猜）
    private func money(_ value: CreditAmount?) -> String {
        value.flatMap { UsageDisplay.money($0) } ?? "—"
    }
}
