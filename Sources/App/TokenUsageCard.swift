// 统计面板的 Token 用量卡和模型卡（token-usage ticket 07）。
// Token 用量卡：分段切换 5 小时 / 周 / 累计；主数字（四类合计，K/M/B）；四类比例条；图例每行显示数值和占比
// （缓存读取通常占九成以上，其余几类在比例条上几乎看不见，靠占比一列补上；不足 1% 写"<1%"）；
// 累计时主数字旁标"自 <起算点>"。模型卡跟随上面的分段。数字由 App 核心 TokenFigure 算好。
// 四类的颜色用系统色（跟随浅色 / 深色），历史卡的柱状图用同一套。

import AppKit
import SwiftUI

struct TokenUsageCard: View {
    /// 还没读到时为 nil
    let figure: TokenFigure?
    @Binding var period: TokenUsagePeriod
    let now: Date

    var body: some View {
        FlyoutCard {
            VStack(alignment: .leading, spacing: 8) {
                FlyoutCardTitle(title: String(localized: "Token Usage")) {
                    FlyoutSegments(options: [(.fiveHour, String(localized: "5 hours")),
                                             (.sevenDay, String(localized: "Week")),
                                             (.cumulative, String(localized: "Cumulative"))],
                                   selection: $period)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: figure?.total ?? "—")
                        .font(.system(size: 30, weight: .light))
                        .monospacedDigit()
                    if let since = figure?.since {
                        Text("since \(TokenUsageDisplay.origin(since, now: now))")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
                proportionBar
                legend
            }
        }
    }

    private var proportionBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(figure?.parts ?? [], id: \.kind) { part in
                    Rectangle()
                        .fill(part.kind.color)
                        .frame(width: geometry.size.width * part.fraction)
                }
            }
            .frame(width: geometry.size.width, alignment: .leading)
        }
        .frame(height: 8)
        .background(Color.primary.opacity(0.08))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private var legend: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(TokenKind.allCases, id: \.self) { kind in
                let part = figure?.parts.first { $0.kind == kind }
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(kind.color).frame(width: 8, height: 8)
                        Text(verbatim: kind.title)
                    }
                    Text(verbatim: part?.value ?? "—")
                        .gridColumnAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(verbatim: part?.share ?? "—")
                        .foregroundColor(.secondary)
                        .gridColumnAlignment(.trailing)
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }
}

struct ModelsCard: View {
    let figure: TokenFigure?

    var body: some View {
        FlyoutCard {
            VStack(alignment: .leading, spacing: 8) {
                FlyoutCardTitle(title: String(localized: "Models")) { EmptyView() }
                if let models = figure?.models, !models.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(models, id: \.name) { model in
                            GridRow {
                                Text(verbatim: model.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(verbatim: model.value)
                                    .gridColumnAlignment(.trailing)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Text(verbatim: model.share)
                                    .foregroundColor(.secondary)
                                    .gridColumnAlignment(.trailing)
                                    .frame(minWidth: 34, alignment: .trailing)
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .monospacedDigit()
                } else {
                    Text(verbatim: "—")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

extension TokenKind {
    var title: String {
        switch self {
        case .input: return String(localized: "Input")
        case .output: return String(localized: "Output")
        case .cacheWrite: return String(localized: "Cache write")
        case .cacheRead: return String(localized: "Cache read")
        }
    }

    var color: Color {
        switch self {
        case .input: return Color(nsColor: .systemCyan)
        case .output: return Color(nsColor: .systemPink)
        case .cacheWrite: return Color(nsColor: .systemOrange)
        case .cacheRead: return Color(nsColor: .systemIndigo)
        }
    }
}
