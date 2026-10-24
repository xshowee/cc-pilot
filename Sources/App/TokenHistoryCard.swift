// 统计面板的历史卡（token-usage ticket 07）：四类 token 堆叠柱状图，24 小时（每小时一根）/ 30 天（每天一根）切换。
// 柱高相对最高的一根（App 核心 HistoryBar）；没有用量的格子画一道底色的矮条，看得出时间轴是连续的。
// 每根柱子从下到上依次是输入、输出、缓存写入、缓存读取，颜色同 Token 用量卡。

import SwiftUI

struct TokenHistoryCard: View {
    let bars: [HistoryBar]
    @Binding var range: HistoryRange

    private static let chartHeight: CGFloat = 70

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
