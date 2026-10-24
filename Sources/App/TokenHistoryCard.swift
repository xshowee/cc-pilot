// 统计面板的历史卡（token-usage ticket 07）：四类 token 堆叠柱状图，24 小时（每小时一根）/ 30 天（每天一根）切换。
// 柱高相对最高的一根（App 核心 HistoryBar）；没有用量的格子画一道底色的矮条，看得出时间轴是连续的。
// 每根柱子从下到上依次是输入、输出、缓存写入、缓存读取，颜色同 Token 用量卡。
// 鼠标停在图上（参照 iStat）：吸附到所在的那一格，画一条竖线，旁边的提示框写这一格的时间、四类 token 和合计；
// 停在哪一格、竖线和提示框放哪由 App 核心 HistoryHover 算。提示框用系统的控件底色，跟随浅色 / 深色。

import AppKit
import SwiftUI

struct TokenHistoryCard: View {
    let bars: [HistoryBar]
    @Binding var range: HistoryRange

    /// 鼠标在图上的横坐标（以图的左边为 0）；不在图上时为 nil
    @State private var hoverX: CGFloat?
    @State private var tooltipSize: CGSize = .zero

    private static let chartHeight: CGFloat = 70
    private static let tooltipGap: CGFloat = 6

    var body: some View {
        FlyoutCard {
            VStack(alignment: .leading, spacing: 8) {
                FlyoutCardTitle(title: String(localized: "History")) {
                    FlyoutSegments(options: [(.hours, String(localized: "24 hours")),
                                             (.days, String(localized: "30 days"))],
                                   selection: $range)
                }
                chart
                axis
            }
        }
        // 提示框可能高出图，叠在卡片上面的内容之上
        .zIndex(hoverX == nil ? 0 : 1)
    }

    private var chart: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(bars, id: \.start) { bar in
                column(bar)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.chartHeight, alignment: .bottom)
        .accessibilityHidden(true)
        .overlay(GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let x = hoverX,
                   let index = HistoryHover.index(x: x, width: geometry.size.width, count: bars.count) {
                    hoverMarks(index: index, width: geometry.size.width)
                }
                // 面板不是 key 窗口，SwiftUI 的悬停不一定触发；用始终有效的跟踪区域取鼠标位置
                MouseTracker { hoverX = $0 }
            }
        })
    }

    @ViewBuilder private func hoverMarks(index: Int, width: CGFloat) -> some View {
        let lineX = HistoryHover.lineX(index: index, width: width, count: bars.count)
        Rectangle()
            .fill(Color.primary.opacity(0.45))
            .frame(width: 1, height: Self.chartHeight)
            .offset(x: lineX - 0.5)
            .allowsHitTesting(false)
        HistoryTooltip(bar: bars[index], range: range)
            .fixedSize()
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { tooltipSize = geometry.size }
                    .onChange(of: geometry.size) { tooltipSize = $0 }
            })
            .offset(x: HistoryHover.tooltipX(lineX: lineX, tooltipWidth: tooltipSize.width, width: width,
                                             gap: Self.tooltipGap),
                    y: Self.chartHeight - tooltipSize.height)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func column(_ bar: HistoryBar) -> some View {
        let total = bar.tokens.total
        if total == 0 {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.08))
                .frame(height: 2)
        } else {
            let height = max(2, Self.chartHeight * bar.height)
            VStack(spacing: 0) {
                ForEach(TokenKind.allCases.reversed(), id: \.self) { kind in
                    Rectangle()
                        .fill(kind.color)
                        .frame(height: height * CGFloat(kind.count(in: bar.tokens)) / CGFloat(total))
                }
            }
            .frame(height: height, alignment: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }

    private var axis: some View {
        HStack {
            switch range {
            case .hours:
                Text("24h ago"); Spacer(); Text("12h ago"); Spacer(); Text("Now")
            case .days:
                Text("30d ago"); Spacer(); Text("15d ago"); Spacer(); Text("Today")
            }
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
    }
}

/// 悬停提示框：时间、四类 token（色点、名称、数值）、合计
private struct HistoryTooltip: View {
    let bar: HistoryBar
    let range: HistoryRange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: TokenUsageDisplay.historySlot(bar.start, range: range))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(TokenKind.allCases, id: \.self) { kind in
                    GridRow {
                        HStack(spacing: 5) {
                            Circle().fill(kind.color).frame(width: 7, height: 7)
                            Text(verbatim: kind.title)
                        }
                        Text(verbatim: TokenUsageDisplay.compact(kind.count(in: bar.tokens)))
                            .gridColumnAlignment(.trailing)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Total")
                    Text(verbatim: TokenUsageDisplay.compact(bar.tokens.total))
                        .fontWeight(.semibold)
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

/// 报告鼠标在视图里的横坐标（离开时报 nil）。跟踪区域用 .activeAlways：所在窗口不是 key 也照样有效
private struct MouseTracker: NSViewRepresentable {
    let onMove: (CGFloat?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onMove = onMove
    }

    final class TrackingView: NSView {
        var onMove: ((CGFloat?) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.activeAlways, .inVisibleRect, .mouseMoved,
                                                     .mouseEnteredAndExited],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onMove?(nil) }

        /// 不拦截点击：点击照常落到下面（图上本来也没有可点的东西）
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func report(_ event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil).x)
        }
    }
}
