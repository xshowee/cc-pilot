// 侧边统计面板的内容（token-usage ticket 07，原型方案 A：iStat 式圆角卡片堆叠）。从上到下：
//   顶部       账号邮箱、订阅等级
//   圆环卡     5 小时窗口、周窗口的剩余百分比与重置倒计时（QuotaRingView）
//   Token 用量卡  分段切换 5 小时 / 周 / 累计；主数字、四类比例条、图例（数值与占比）；累计时标"自 <起算点>"
//   模型卡     跟随上面的分段
//   历史卡     四类 token 堆叠柱状图，24 小时 / 30 天（TokenHistoryCard）
//   底部       清空累计，在面板里就地确认（不弹系统对话框）
// 卡片与主面板的档案卡片同一套颜色（Color.primary 的淡底色与描边），跟随系统浅色 / 深色。不加任何说明文字。
// 要显示什么由 App 核心算好（QuotaRing、TokenFigure、HistoryBar），这里只负责画。

import SwiftUI

struct StatsFlyoutView: View {
    let title: String
    let tier: String?
    let account: UsageAccount
    let quota: AccountUsage?
    /// 还没读到时为 nil（数字显示"—"）
    let tokens: AccountTokenUsage?
    let now: Date
    let onClear: () -> Void

    @State private var period: TokenUsagePeriod = .fiveHour
    @State private var range: HistoryRange = .hours
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            FlyoutCard {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    QuotaRingView(ring: QuotaRing.fiveHour(quota, now: now), caption: String(localized: "5 hours"))
                    Spacer(minLength: 0)
                    QuotaRingView(ring: QuotaRing.sevenDay(quota, now: now), caption: String(localized: "Week"))
                    Spacer(minLength: 0)
                }
            }
            TokenUsageCard(figure: figure, period: $period, now: now)
            ModelsCard(figure: figure)
            TokenHistoryCard(bars: tokens.map { HistoryBar.bars($0, range: range) } ?? [], range: $range)
            clearRow
        }
        .padding(8)
        .onChange(of: account) { _ in confirmingClear = false }
    }

    private var figure: TokenFigure? { tokens.map { TokenFigure($0, period: period) } }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let tier {
                Text(verbatim: tier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    @ViewBuilder private var clearRow: some View {
        HStack(spacing: 6) {
            if confirmingClear {
                Text("Clear cumulative usage for \(title)?")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Cancel") { confirmingClear = false }
                    .controlSize(.small)
                Button("Clear") {
                    confirmingClear = false
                    onClear()
                }
                .controlSize(.small)
                .foregroundColor(StatusColor.red)
            } else {
                if let origin = tokens?.cumulative.origin {
                    Text("Cumulative since \(TokenUsageDisplay.origin(origin, now: now))")
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Clear Cumulative") { confirmingClear = true }
                    .controlSize(.small)
                    .disabled(tokens == nil)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}

/// 一张圆角卡片：与主面板档案卡片同样的淡底色和描边
struct FlyoutCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

/// 卡片标题行：左边标题（强调色），右边可放分段切换
struct FlyoutCardTitle<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.accentColor)
            Spacer(minLength: 8)
            accessory
        }
    }
}

/// 小号分段切换。面板不是 key 窗口，系统的分段控件会画成非活动的灰色，所以自己画（样式同原型）
struct FlyoutSegments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                } label: {
                    Text(verbatim: label)
                        .font(.system(size: 11))
                        .foregroundColor(selection == value ? .primary : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selection == value ? Color.primary.opacity(0.12) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}
