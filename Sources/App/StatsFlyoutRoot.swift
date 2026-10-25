// 统计面板窗口里的根视图（token-usage ticket 07）：按 StatsFlyoutController 记着的档案名找到档案和它的账号，
// 取额度（UsageModel，合并了实时额度）和 Token 用量（TokenStatsModel），交给 StatsFlyoutView 画。
// 同一账号的几个档案行得到同一个账号，显示同一份数据。
// 向窗口报告内容大小（窗口按它摆放）和鼠标进出（停在面板上时不收起）。
// 内容比屏幕可用高度还高时，窗口只有可用高度那么高（StatsFlyoutController），内容在里面滚动。
//
// 内容大小用 GeometryReader 的 onAppear / onChange 报告，不用 PreferenceKey：在这个 NSHostingView 里，
// 内容从无到有（鼠标停到行上）之后 onPreferenceChange 不再触发，窗口会一直停在初始高度，内容上下被裁掉（真机验收发现）。

import SwiftUI

struct StatsFlyoutRoot: View {
    static let width: CGFloat = 320

    @ObservedObject var controller: StatsFlyoutController
    @ObservedObject var profiles: ProfileListModel
    @ObservedObject var usage: UsageModel
    @ObservedObject var stats: TokenStatsModel

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(width: Self.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { controller.contentSizeChanged(geometry.size) }
                        .onChange(of: geometry.size) { controller.contentSizeChanged($0) }
                })
        }
        .scrollIndicators(.automatic)
        .onHover { controller.flyout(hovering: $0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        if let name = controller.hover.profile,
           let profile = profiles.profiles.first(where: { $0.name == name }),
           let target = StatsFlyoutTarget(profile: profile) {
            let quota = usage.board.usage(for: target.account)
            let request = TokenStatsModel.Request(account: target.account, resets: KnownResets(usage: quota))
            StatsFlyoutView(title: target.email ?? profile.name,
                            tier: AccountText.tier(for: profile),
                            account: target.account,
                            quota: quota,
                            tokens: stats.loaded[target.account],
                            now: usage.now,
                            onClear: { stats.clear(target.account) })
                .onAppear { stats.show(request) }
                .onChange(of: request) { stats.show($0) }
                .onDisappear { stats.hide() }
        }
    }
}
