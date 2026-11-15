// 统计面板窗口里的根视图（token-usage ticket 07）：按 StatsFlyoutController 记着的行（工具 + 档案名）找到档案和它的账号，
// 取额度（UsageModel，合并了实时额度）和 Token 用量（TokenStatsModel），交给 StatsFlyoutView 画。
// 同一账号的几个档案行得到同一个账号，显示同一份数据。ChatGPT 档案（chatgpt-profiles ticket 10）用同一个面板：
// 标题是 ChatGPT 账号的邮箱，等级处显示套餐（优先用最近一次刷新时响应里的），窗口按 ChatGPT 账号自己的额度对齐。
// Kimi Code 卡片（ADR 0007）也用这个窗口，但内容是 Base URL 和模型列表（KimiFlyoutView），不读 Token 用量。
// Antigravity 卡片（antigravity-usage ticket 02）：上方显示看板算好的套餐和各组圆环，下方复用三类（无缓存写入）Token 用量卡、模型卡与历史卡。
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
    @ObservedObject var chatgpt: ChatGPTProfileListModel
    @ObservedObject var usage: UsageModel
    @ObservedObject var stats: TokenStatsModel
    @ObservedObject var kimi: KimiModel
    @ObservedObject var antigravity: AntigravityModel

    var body: some View {
        let request = tokenRequest
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
        .onAppear { applyTokenRequest(request) }
        .onChange(of: request) { newValue in applyTokenRequest(newValue) }
        .onDisappear { stats.hide() }
    }

    // 触发与取消 Token 读取收口在顶层容器单一 tokenRequest 上，不放在各分支子视图里，
    // 避免鼠标跨段快速移动时新视图的 onAppear 与旧视图的 onDisappear 先后不定导致误关。
    // Kimi Code 不触发 Token 读取（tokenRequest 为 nil），Antigravity 从账本按 antigravity:<邮箱> 读取。
    @ViewBuilder private var content: some View {
        if let row = controller.hover.row, row.section == .kimi {
            if kimi.names.contains(row.name) {
                KimiFlyoutView(name: row.name, models: usage.kimiModels[row.name],
                               isRefreshing: usage.isRefreshingKimi(row.name), now: usage.now)
            }
        } else if let row = controller.hover.row, row.section == .antigravity {
            // 时钟同卡片（UsageModel.now）
            if let flyout = antigravity.board.flyout(for: row.name, now: usage.now) {
                AntigravityFlyoutView(flyout: flyout, stats: stats, now: usage.now)
            }
        } else if let shown {
            let quota = usage.board.usage(for: shown.target.account)
            StatsFlyoutView(title: shown.title,
                            tier: shown.tier,
                            account: shown.target.account,
                            quota: quota,
                            tokens: stats.loaded[shown.target.account],
                            now: usage.now,
                            onClear: { stats.clear(shown.target.account) })
        }
    }

    private var tokenRequest: StatsFlyoutTokenRequest? {
        StatsFlyoutTokenRequest.resolve(row: controller.hover.row,
                                        claudeCode: profiles.profiles,
                                        chatgpt: chatgpt.profiles,
                                        board: usage.board,
                                        antigravity: antigravity.board)
    }

    private func applyTokenRequest(_ request: StatsFlyoutTokenRequest?) {
        if let request {
            stats.show(request)
        } else {
            stats.hide()
        }
    }

    /// 鼠标停着的行：账号、标题（邮箱，没有时用档案名）、等级或套餐
    private var shown: (target: StatsFlyoutTarget, title: String, tier: String?)? {
        guard let row = controller.hover.row else { return nil }
        switch row.section {
        case .kimi, .antigravity:
            return nil
        case .tool(.claudeCode):
            guard let profile = profiles.profiles.first(where: { $0.name == row.name }),
                  let target = StatsFlyoutTarget(profile: profile) else { return nil }
            return (target, target.email ?? profile.name, AccountText.tier(for: profile))
        case .tool(.chatgpt):
            guard let profile = chatgpt.profiles.first(where: { $0.name == row.name }),
                  let target = StatsFlyoutTarget(chatgpt: profile) else { return nil }
            return (target, target.email ?? profile.name,
                    ChatGPTAccountText.plan(for: profile, reported: usage.reportedPlan(for: profile)))
        }
    }
}
