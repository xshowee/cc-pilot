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
    var kinds: [TokenKind] = TokenKind.allCases
    /// 仅 Antigravity 面板展示等效 API 费用与缓存节省；Claude / ChatGPT 保持原样
    var showsCost: Bool = false

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
                if showsCost {
                    costSummary
                }
                proportionBar
                legend
            }
        }
    }

    @ViewBuilder private var costSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: figure?.cost?.totalCostText ?? "—")
                    .foregroundColor(figure?.cost?.totalCostUSD == nil ? .secondary : .primary)
                if let savings = figure?.cost?.cacheSavingsText {
                    Text("Saved \(savings)")
                        .foregroundColor(.secondary)
                }
            }
            .font(.callout)
            .monospacedDigit()
            if let unpriced = figure?.cost?.unpricedModels, !unpriced.isEmpty {
                Text(verbatim: unpricedFootnote(unpriced))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func unpricedFootnote(_ models: [String]) -> String {
        let separator = String(localized: "list-separator", defaultValue: ", ")
        let list = models.joined(separator: separator)
        if models.count == 1 {
            return String(localized: "Excludes unpriced model: \(list)")
        }
        return String(localized: "Excludes unpriced models: \(list)")
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
            ForEach(figure?.kinds ?? kinds, id: \.self) { kind in
                let part = figure?.parts.first { $0.kind == kind }
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(kind.color).frame(width: 8, height: 8)
                        Text(verbatim: kind.title)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    valueAndShareCells(value: part?.value ?? "—", share: part?.share ?? "—")
                }
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }
}

struct ModelsCard: View {
    let figure: TokenFigure?
    /// 仅 Antigravity 面板展示单模型等效 API 费用；Claude / ChatGPT 保持三列原样
    var showsCost: Bool = false

    var body: some View {
        FlyoutCard {
            VStack(alignment: .leading, spacing: 8) {
                FlyoutCardTitle(title: String(localized: "Models")) { EmptyView() }
                if let models = figure?.models, !models.isEmpty {
                    Grid(
                        alignment: .leadingFirstTextBaseline,
                        horizontalSpacing: showsCost ? 8 : 10,
                        verticalSpacing: 4
                    ) {
                        ForEach(models, id: \.name) { model in
                            GridRow {
                                Text(verbatim: model.name)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help(model.name)
                                valueAndShareCells(
                                    value: model.value,
                                    share: model.share,
                                    shareMinWidth: showsCost ? 0 : 34)
                                if showsCost {
                                    costCell(for: model)
                                }
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

    @ViewBuilder private func costCell(for model: TokenFigure.ModelRow) -> some View {
        let text = model.costText ?? (model.isUnpriced ? String(localized: "Unpriced") : "—")
        Text(verbatim: text)
            .foregroundColor(model.isUnpriced || model.costText == nil ? .secondary : .primary)
            .fixedSize(horizontal: true, vertical: false)
            .gridColumnAlignment(.trailing)
    }
}

/// 图例和模型卡一行右边的格：数值（右对齐）、占比（次要颜色）；第一列占满剩余宽度，数值列紧凑贴右
@ViewBuilder private func valueAndShareCells(value: String, share: String, shareMinWidth: CGFloat = 34) -> some View {
    Text(verbatim: value)
        .fixedSize(horizontal: true, vertical: false)
        .gridColumnAlignment(.trailing)
    Text(verbatim: share)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .gridColumnAlignment(.trailing)
        .frame(minWidth: shareMinWidth > 0 ? shareMinWidth : nil, alignment: .trailing)
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
