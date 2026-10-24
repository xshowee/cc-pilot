// 统计面板窗口里的根视图（token-usage ticket 07）：按 StatsFlyoutController 记着的档案名找到档案和它的账号，
// 取额度（UsageModel，合并了实时额度）和 Token 用量（TokenStatsModel），交给 StatsFlyoutView 画。
// 同一账号的几个档案行得到同一个账号，显示同一份数据。
// 向窗口报告内容大小（窗口按它摆放）和鼠标进出（停在面板上时不收起）。

import SwiftUI

struct StatsFlyoutRoot: View {
    static let width: CGFloat = 320

    @ObservedObject var controller: StatsFlyoutController
    @ObservedObject var profiles: ProfileListModel
    @ObservedObject var usage: UsageModel
    @ObservedObject var stats: TokenStatsModel

    var body: some View {
        content
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: FlyoutSizeKey.self, value: geometry.size)
            })
            .onPreferenceChange(FlyoutSizeKey.self) { controller.contentSizeChanged($0) }
            .onHover { controller.flyout(hovering: $0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        if let name = controller.hover.profile,
           let profile = profiles.profiles.first(where: { $0.name == name }),
           let target = StatsFlyoutTarget(profile: profile) {
            let quota = usage.board.usage(for: target.account)
            let request = Request(account: target.account, resets: KnownResets(usage: quota))
            StatsFlyoutView(title: target.email ?? profile.name,
                            tier: target.tier.map(AccountText.tierName),
                            account: target.account,
                            quota: quota,
                            tokens: stats.loaded[target.account],
                            now: usage.now,
                            onClear: { stats.clear(target.account) })
                .onAppear { stats.show(request.account, resets: request.resets) }
                .onChange(of: request) { stats.show($0.account, resets: $0.resets) }
                // 滚动窗口随时间移动：界面时钟走一格就重读
                .onChange(of: usage.now) { _ in stats.reload() }
                .onDisappear { stats.hide() }
        }
    }

    private struct Request: Equatable {
        let account: UsageAccount
        let resets: KnownResets
    }
}

private struct FlyoutSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
