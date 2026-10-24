// 点击菜单栏图标后弹出的面板：标题与"刷新全部"、未接入 zsh 时的提示（ticket 25）、
// 档案卡片列表（点击即切换，可单独刷新额度、删除）、添加档案的输入框（ticket 09，点底栏按钮后出现）、
// 底栏（添加档案、设置菜单、退出）。"菜单栏只显示图标"在设置菜单里。
// 鼠标停在已登录的档案卡片上时，左侧弹出它所在账号的统计面板（token-usage ticket 07，StatsFlyoutController）；
// 设置菜单里点"清空全部账号的累计…"后，底栏上方出现确认条（ClearAllBanner）。
// 打开面板只重读档案列表、当前档案和 zsh 接入状态，不刷新额度。

import SwiftUI

struct PanelView: View {
    @ObservedObject var profiles: ProfileListModel
    @ObservedObject var current: CurrentProfileModel
    @ObservedObject var usage: UsageModel
    @ObservedObject var actions: ProfileActionsModel
    @EnvironmentObject private var shellIntegration: ShellIntegrationModel
    @EnvironmentObject private var tokenStats: TokenStatsModel
    @StateObject private var flyout = StatsFlyoutController()

    @State private var addingProfile = false
    /// 档案列表内容的实际高度（用来决定要不要显示滚动条）
    @State private var listHeight: CGFloat = 0

    /// 档案列表最多这么高，再多就滚动
    private static let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Profiles")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                refreshAllButton
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if shellIntegration.showsNotConnectedHint {
                ShellIntegrationBanner { shellIntegration.connectWithConsent() }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(profiles.profiles) { profile in
                        SwitchableProfileRow(
                            profile: profile,
                            isCurrent: profile.name == current.name,
                            usage: usage.usage(for: profile),
                            now: usage.now,
                            isRefreshing: usage.isRefreshing(profile),
                            onRefresh: profile.usageAccount == nil ? nil : {
                                usage.refresh(profile, in: profiles.profiles)
                            },
                            onDelete: (
                                blocker: actions.removalBlocker(profile: profile.name,
                                                                currentProfile: current.name),
                                action: { actions.remove(profile.name, currentProfile: current.name) }
                            ),
                            // 未登录的档案没有统计面板：停在上面等同于离开账号行
                            onHover: profile.usageAccount == nil ? nil : { hovering in
                                flyout.row(profile.name, hovering: hovering)
                            }
                        ) {
                            current.switchTo(profile.name)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ListHeightKey.self, value: geometry.size.height)
                })
            }
            // 内容高度一变（展开/收起额度详情），系统就会闪一下滚动条；放得下时干脆不显示，
            // 只有档案多到超出最大高度、真的需要滚动时才显示
            .scrollIndicators(listHeight > Self.maxListHeight ? .automatic : .never)
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            .frame(maxHeight: Self.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)

            if let pending = actions.pending {
                PendingChangeBanner(change: pending) { actions.dismissPending() }
            }
            if tokenStats.confirmingClearAll {
                ClearAllBanner(onCancel: { tokenStats.confirmingClearAll = false },
                               onClear: { tokenStats.clearAll() })
            }
            if addingProfile {
                Divider()
                AddProfileForm(actions: actions, isPresented: $addingProfile)
            }
            Divider()
            PanelFooter(addDisabled: addingProfile || actions.isOpening) { addingProfile = true }
        }
        .frame(width: 340)
        .background(WindowReader { flyout.attach(to: $0) })
        .onAppear {
            profiles.reload(); current.reload(); actions.update(with: profiles.profiles)
            // 终端里可能 ccp init / ccp uninstall 过（ticket 25 的提示随之更新）
            shellIntegration.refresh()
            flyout.install(StatsFlyoutRoot(controller: flyout, profiles: profiles, usage: usage, stats: tokenStats))
        }
        .onDisappear {
            flyout.dismiss()
            tokenStats.confirmingClearAll = false
        }
        .onChange(of: profiles.profiles) { list in
            actions.update(with: list)
            flyout.rowsChanged(Set(list.filter { $0.usageAccount != nil }.map(\.name)))
        }
    }

    private var refreshAllButton: some View {
        Button {
            usage.refreshAll(profiles.profiles)
        } label: {
            Group {
                if usage.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .foregroundColor(.secondary)
        // 正在刷新，或每个账号都还在频率限制的等待期内（ticket 12）时不可用
        .disabled(usage.isRefreshing || !usage.canRefreshAny(profiles.profiles))
        .help(Text("Refresh usage for all accounts"))
        .accessibilityLabel(Text("Refresh All"))
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
