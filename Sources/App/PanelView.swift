// 点击菜单栏图标后弹出的面板：标题与"刷新全部"、未接入 zsh 时的提示（ticket 25）、
// 档案卡片列表（点击即切换，可单独刷新额度、删除）、添加档案的输入框（ticket 09，点底栏按钮后出现）、
// 底栏（添加档案、设置菜单、退出）。"菜单栏只显示图标"在设置菜单里。
// 鼠标停在已登录的档案卡片上时，左侧弹出它所在账号的统计面板（token-usage ticket 07，StatsFlyoutController；
// ChatGPT 卡片同样，chatgpt-profiles ticket 10）。两个工具可以有同名档案，面板的行按工具 + 档案名区分；
// 设置菜单里点"清空全部账号的累计…"后，底栏上方出现确认条（ClearAllBanner）。
// 档案分 Claude Code、ChatGPT 上下两段（chatgpt-profiles ticket 02）；两段都显示时，每段前面是带工具标识的
// 分割线（ToolSectionDivider）；没有 ChatGPT 默认档案 ~/.codex 时不显示 ChatGPT 一段（也就没有分割线）。
// Claude Code 一段总是显示（保持原有行为）。
// 添加过 Kimi Code 账号时，最下面多一段 Kimi Code（ADR 0007）：每个账号一张额度卡片（KimiCard），
// 不能切换、没有统计面板；添加入口同其他账号（AddProfileForm 里选 Kimi Code），删除先在底栏上方确认（KimiRemovalBanner）。
// 打开面板只重读档案列表、当前档案和 zsh 接入状态，不刷新额度。
// 打开时面板若离开了菜单栏（过夜后可能往下掉），PanelPositionGuard 把它挪回菜单栏下。
// 档案列表不设固定的最大高度：面板随档案多少一起变高，平时不滚动、不显示滚动条。只有档案多到面板放不下
// （超出所在屏幕的可用区域，PanelScreenTracker）时，列表才限高到屏幕放得下的高度并可以滚动（不显示滚动条），
// 标题和底栏始终在屏幕内（MenuBarPanelPlacement.listHeightLimit）。

import SwiftUI

struct PanelView: View {
    @ObservedObject var profiles: ProfileListModel
    @ObservedObject var current: CurrentProfileModel
    @ObservedObject var usage: UsageModel
    @ObservedObject var actions: ProfileActionsModel
    @ObservedObject var chatgpt: ChatGPTProfileListModel
    @EnvironmentObject private var shellIntegration: ShellIntegrationModel
    @EnvironmentObject private var tokenStats: TokenStatsModel
    @EnvironmentObject private var kimi: KimiModel
    @StateObject private var flyout = StatsFlyoutController()
    @StateObject private var positionGuard = PanelPositionGuard()
    @StateObject private var screen = PanelScreenTracker()
    /// 点击 ChatGPT 档案时的切换（后台执行 ccp chatgpt use，ticket 04）
    @StateObject private var chatgptSwitch = ChatGPTSwitchModel()

    @State private var addingProfile = false
    /// 档案列表内容本身的高度（不受限高影响）
    @State private var listHeight: CGFloat = 0
    /// 列表上方（标题、提示条）和下方（确认条、添加表单、底栏）的高度
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// 档案列表最多多高：还不知道面板在哪个屏幕时不限
    private var listHeightLimit: CGFloat {
        screen.visibleFrame.map { MenuBarPanelPlacement.listHeightLimit(chrome: headerHeight + footerHeight, within: $0) } ?? .infinity
    }

    var body: some View {
        let overflowing = listHeight > listHeightLimit
        VStack(alignment: .leading, spacing: 0) {
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
            }
            .background(measuring($headerHeight))

            ScrollView {
                VStack(spacing: 6) {
                    if chatgpt.isVisible || kimi.isVisible {
                        ToolSectionDivider(tool: .claudeCode)
                    }
                    ForEach(profiles.profiles) { profile in
                        SwitchableProfileRow(
                            profile: profile,
                            isCurrent: profile.name == current.name,
                            isViewing: flyout.hover.row == StatsFlyoutRow(tool: .claudeCode, name: profile.name),
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
                            onHover: StatsFlyoutTarget(profile: profile) == nil ? nil : { hovering in
                                flyout.row(StatsFlyoutRow(tool: .claudeCode, name: profile.name), hovering: hovering)
                            }
                        ) {
                            current.switchTo(profile.name)
                        }
                        .statsFlyoutAnchor(StatsFlyoutRow(tool: .claudeCode, name: profile.name), controller: flyout)
                    }
                    if chatgpt.isVisible {
                        chatgptSection
                    }
                    if kimi.isVisible {
                        KimiSectionDivider()
                            .padding(.top, 4)
                        ForEach(kimi.names, id: \.self) { name in
                            KimiCard(name: name, usage: usage.kimiUsage(name), now: usage.now,
                                     isRefreshing: usage.isRefreshingKimi(name),
                                     onRefresh: { usage.refreshKimi(name) },
                                     onDelete: { kimi.confirmingRemoval = name },
                                     onCopyKey: { kimi.copyKey(name) },
                                     copyNotice: kimi.copyNotice?.name == name ? kimi.copyNotice : nil)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .background(measuring($listHeight))
            }
            // 从不显示滚动条（接着鼠标时系统会让它一直显示，不好看）；放得下时也不能滚动，
            // 看起来和没有 ScrollView 一样
            .scrollIndicators(.never)
            .scrollDisabled(!overflowing)
            .frame(maxHeight: listHeightLimit)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                if let pending = actions.pending {
                    PendingChangeBanner(change: pending.change) { actions.dismissPending() }
                }
                if tokenStats.confirmingClearAll {
                    ClearAllBanner(onCancel: { tokenStats.confirmingClearAll = false },
                                   onClear: { tokenStats.clearAll() })
                }
                if let name = kimi.confirmingRemoval {
                    KimiRemovalBanner(name: name, onCancel: { kimi.confirmingRemoval = nil },
                                      onDelete: { kimi.remove(name) })
                }
                if addingProfile {
                    Divider()
                    AddProfileForm(actions: actions, kimi: kimi, isPresented: $addingProfile,
                                   offersChatGPT: chatgpt.isVisible)
                }
                Divider()
                PanelFooter(addDisabled: addingProfile || actions.isOpening) { addingProfile = true }
            }
            .background(measuring($footerHeight))
        }
        .frame(width: 340)
        .background(WindowReader { window in
            flyout.attach(to: window)
            positionGuard.attach(to: window)
            screen.attach(to: window)
        })
        .onAppear {
            profiles.reload(); current.reload(); actions.update(with: profiles.profiles)
            chatgpt.reload(); actions.update(withChatGPT: chatgpt.profiles)
            // 终端里可能 ccp init / ccp uninstall 过（ticket 25 的提示随之更新）
            shellIntegration.refresh()
            kimi.reload()
            flyout.install(StatsFlyoutRoot(controller: flyout, profiles: profiles, chatgpt: chatgpt, usage: usage,
                                           stats: tokenStats))
        }
        .onDisappear {
            flyout.dismiss()
            tokenStats.confirmingClearAll = false
            kimi.confirmingRemoval = nil
        }
        .onChange(of: profiles.profiles) { list in
            actions.update(with: list)
            flyout.rowsChanged(StatsFlyoutRow.rows(claudeCode: list, chatgpt: chatgpt.profiles))
        }
        .onChange(of: chatgpt.profiles) { list in
            actions.update(withChatGPT: list)
            flyout.rowsChanged(StatsFlyoutRow.rows(claudeCode: profiles.profiles, chatgpt: list))
        }
    }

    /// ChatGPT 一段：分割线 + 档案卡片，点击即切换（ticket 04），刷新额度（ticket 07），删除（ticket 06），
    /// 停在有账号的卡片上弹出统计面板（ticket 10）。
    /// 正在后台切换时卡片不可点击。
    @ViewBuilder private var chatgptSection: some View {
        ToolSectionDivider(tool: .chatgpt)
            .padding(.top, 4)
        ForEach(chatgpt.profiles) { profile in
            ChatGPTProfileCard(
                profile: profile, isCurrent: profile.name == chatgpt.currentName,
                onSelect: chatgptSwitch.isSwitching ? nil : {
                    chatgptSwitch.switchTo(profile.name, currentName: chatgpt.currentName) { chatgpt.reload() }
                },
                usage: usage.usage(for: profile), now: usage.now,
                reportedPlan: usage.reportedPlan(for: profile),
                isRefreshing: usage.isRefreshing(profile),
                onRefresh: profile.usageAccount == nil ? nil : {
                    usage.refresh(profile, in: chatgpt.profiles)
                },
                onDelete: (
                    blocker: actions.chatgptRemovalBlocker(profile: profile.name, currentProfile: chatgpt.currentName,
                                                           launchdCodexHome: chatgpt.launchdCodexHome),
                    action: {
                        actions.removeChatGPT(profile.name, currentProfile: chatgpt.currentName,
                                              launchdCodexHome: chatgpt.launchdCodexHome)
                    }
                ),
                isViewing: flyout.hover.row == StatsFlyoutRow(tool: .chatgpt, name: profile.name),
                // 没有账号（未登录、API key）的档案没有统计面板：停在上面等同于离开账号行
                onHover: StatsFlyoutTarget(chatgpt: profile) == nil ? nil : { hovering in
                    flyout.row(StatsFlyoutRow(tool: .chatgpt, name: profile.name), hovering: hovering)
                })
            .statsFlyoutAnchor(StatsFlyoutRow(tool: .chatgpt, name: profile.name), controller: flyout)
        }
    }

    private var refreshAllButton: some View {
        Button {
            usage.refreshAll(profiles.profiles, chatgpt: chatgpt.profiles, kimi: kimi.names)
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
        .disabled(usage.isRefreshing || !usage.canRefreshAny(profiles.profiles, chatgpt: chatgpt.profiles,
                                                            kimi: kimi.names))
        .help(Text("Refresh usage for all accounts"))
        .accessibilityLabel(Text("Refresh All"))
    }

    /// 把所在视图的高度写进 height（放在 background 里）。直接写 @State 而不用 PreferenceKey：
    /// 实测（macOS，2026-11-05）用 PreferenceKey 从 ScrollView 里报出的列表高度一直是 0。
    private func measuring(_ height: Binding<CGFloat>) -> some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { height.wrappedValue = geometry.size.height }
                .onChange(of: geometry.size.height) { height.wrappedValue = $0 }
        }
    }
}
