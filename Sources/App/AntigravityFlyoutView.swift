// 鼠标停在 Antigravity 卡片上时，侧边面板里的内容（ticket 05，spec "界面"统计面板；数据见 App 核心
// StatsFlyout+Antigravity.swift）。与其他统计面板共用同一个窗口（StatsFlyoutController），样式同 StatsFlyoutView 的卡片。
// 从上到下：
//   顶部     邮箱、套餐（旧快照的邮箱用次要颜色，同卡片）
//   圆环卡   每组一张：组名（AntigravityText.groupTitle），每个桶一个圆环（QuotaRingView，顺序同卡片，每行最多两个），
//            同组同窗口重复的圆环下面带区分标签；下面是组内模型（没有时不显示）
//   Token 用量 / 模型 / 历史 / 清空累计：三类视图（TokenKind.withoutCacheWrite），复用 StatsFlyoutView 卡片组件。

import SwiftUI

struct AntigravityFlyoutView: View {
    let flyout: AntigravityFlyout
    @ObservedObject var stats: TokenStatsModel
    let now: Date

    @State private var period: TokenUsagePeriod = .fiveHour
    @State private var range: HistoryRange = .hours

    /// 面板内宽 320 − 2×8 − 2×12 = 280，放得下两个圆环（96pt 圆环，留出倒计时、区分标签的宽度）
    private static let ringsPerRow = 2
    private static let slotWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(Array(flyout.groups.enumerated()), id: \.offset) { _, group in
                FlyoutCard {
                    VStack(alignment: .leading, spacing: 10) {
                        FlyoutCardTitle(title: AntigravityText.groupTitle(group.display)) { EmptyView() }
                        rings(group.rings)
                        if !group.display.models.isEmpty {
                            models(group.display.models)
                        }
                    }
                }
            }
            TokenUsageCard(figure: figure, period: $period, now: now, kinds: TokenKind.withoutCacheWrite, showsCost: true)
            ModelsCard(figure: figure, showsCost: true)
            TokenHistoryCard(
                bars: tokens.map { HistoryBar.bars($0, range: range, kinds: TokenKind.withoutCacheWrite) } ?? [],
                range: $range,
                kinds: TokenKind.withoutCacheWrite)
            FlyoutClearCumulativeRow(
                title: flyout.email,
                origin: tokens?.cumulative.origin,
                canClear: tokens != nil,
                now: now,
                resetKey: account.id,
                onClear: { stats.clear(account) })
        }
        .padding(StatsFlyoutView.inset)
    }

    private var account: UsageAccount {
        .antigravity(cardEmail: flyout.email)
    }

    private var tokens: AccountTokenUsage? { stats.loaded[account] }

    private var figure: TokenFigure? {
        tokens.map { TokenFigure($0, period: period, kinds: TokenKind.withoutCacheWrite, includeCost: true) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: flyout.email)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(flyout.isOldSnapshot ? Color.secondary : nil)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let tier = flyout.tierName {
                    Text(verbatim: tier)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
            }
            if let liveSpeed = flyout.visibleLiveSpeed {
                Text(verbatim: AntigravityText.liveSpeed(liveSpeed))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    /// 每行最多两个；多于两个时最后一行不满也按列对齐
    private func rings(_ rings: [AntigravityFlyout.Ring]) -> some View {
        let rows = stride(from: 0, to: rings.count, by: Self.ringsPerRow).map {
            Array(rings[$0..<min($0 + Self.ringsPerRow, rings.count)])
        }
        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 0)
                    ForEach(Array(row.enumerated()), id: \.offset) { _, ring in
                        ringView(ring)
                        Spacer(minLength: 0)
                    }
                    if rows.count > 1 && row.count < Self.ringsPerRow {
                        ForEach(row.count..<Self.ringsPerRow, id: \.self) { _ in
                            Color.clear.frame(width: Self.slotWidth, height: 1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func ringView(_ ring: AntigravityFlyout.Ring) -> some View {
        QuotaRingView(ring: ring.ring, caption: AntigravityText.ringCaption(ring.bucket),
                      label: ring.bucket.extraLabel)
            .frame(width: Self.slotWidth)
    }

    private func models(_ models: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                Text(verbatim: model)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
