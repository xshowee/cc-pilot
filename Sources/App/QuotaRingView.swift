// 统计面板圆环卡里的一个窗口（token-usage ticket 07）：圆环长度是剩余比例，颜色同档案行（UsageTint，ticket 06）；
// 中间是剩余百分比和窗口名，下方是重置倒计时。没有数字（没有数据、已重置待刷新）时显示"—"、不画弧。

import SwiftUI

struct QuotaRingView: View {
    let ring: QuotaRing
    let caption: String

    private static let size: CGFloat = 96
    private static let lineWidth: CGFloat = 8

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: Self.lineWidth)
                if let remaining = ring.remaining {
                    Circle()
                        .trim(from: 0, to: CGFloat(remaining) / 100)
                        .stroke(arcColor, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    percent
                    Text(verbatim: caption)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(Self.lineWidth / 2)
            .frame(width: Self.size, height: Self.size)
            Text(verbatim: countdownText)
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var percent: some View {
        if let remaining = ring.remaining {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: "\(remaining)")
                    .font(.system(size: 24, weight: .light))
                Text(verbatim: "%")
                    .font(.system(size: 12))
            }
            .monospacedDigit()
            .foregroundColor(ring.tint == .stale ? ring.tint.color : nil)
        } else {
            Text(verbatim: "—")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.secondary)
        }
    }

    /// 过期灰本身很深（为了菜单栏上的文字可读），弧用淡一些的，同档案行的进度条
    private var arcColor: Color {
        let color = ring.tint.color ?? Color.primary.opacity(0.45)
        return ring.tint == .stale ? color.opacity(0.45) : color
    }

    private var countdownText: String {
        guard let countdown = ring.countdown else { return "—" }
        return String(localized: "Resets in \(ResetCountdownText.text(countdown))")
    }
}

/// 重置倒计时的文字（"2 小时 13 分"）
enum ResetCountdownText {
    static func text(_ countdown: ResetCountdown) -> String {
        switch countdown {
        case .daysHours(let days, let hours): return String(localized: "\(days)d \(hours)h")
        case .hoursMinutes(let hours, let minutes): return String(localized: "\(hours)h \(minutes)m")
        case .minutes(let minutes): return String(localized: "\(minutes)m")
        }
    }
}
