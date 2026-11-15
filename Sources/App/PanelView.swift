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
// 不能切换；鼠标停在卡片上时，同一个侧边面板显示 Base URL 和模型列表（KimiFlyoutView）；添加入口同其他账号（AddProfileForm 里选 Kimi Code），删除先在底栏上方确认（KimiRemovalBanner）；
// 套餐有效期在底栏上方的编辑条里填（KimiExpiryBanner）。
// 添加过 Antigravity 账号时，Kimi Code 一段上面多一段 Antigravity（spec "界面"）：每个邮箱一张额度卡片
// （AntigravityAccountCard，只按看板画），不能切换；添加入口同其他账号（AddProfileForm 里选 Antigravity、
// 输入邮箱，ticket 08），删除先在底栏上方确认（AntigravityRemovalBanner）。"刷新全部"也读一次 Antigravity，
// 没有添加 Antigravity 账号时不读。
// Kimi Code 的删除确认条、有效期编辑条和 Antigravity 的删除确认条同一时刻至多一个（accountBanner）：
// 打开一个就换掉另一个；对应的账号没有了、面板关闭时收起。
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
    @EnvironmentObject private var antigravity: AntigravityModel
    @StateObject private var flyout = StatsFlyoutController()
    @StateObject private var positionGuard = PanelPositionGuard()
    @StateObject private var screen = PanelScreenTracker()
    /// 点击 ChatGPT 档案时的切换（后台执行 ccp chatgpt use，ticket 04）
    @StateObject private var chatgptSwitch = ChatGPTSwitchModel()

    @State private var addingProfile = false
    /// 底栏上方此刻的账号确认条 / 编辑条（至多一个）
    @State private var accountBanner: AccountBanner?

    private enum AccountBanner: Equatable {
        /// 确认删除这个 Kimi Code 账号（KimiRemovalBanner）
        case kimiRemoval(String)
        /// 编辑这个 Kimi Code 账号的套餐有效期（KimiExpiryBanner）
        case kimiExpiry(String)
        /// 确认删除这个 Antigravity 邮箱（AntigravityRemovalBanner）
        case antigravityRemoval(String)
    }
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
                    if chatgpt.isVisible || antigravity.isVisible || kimi.isVisible {
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
                    if antigravity.isVisible {
                        AntigravitySectionDivider()
                            .padding(.top, 4)
                        ForEach(antigravity.cards(now: usage.now), id: \.email) { card in
                            antigravityCard(card)
                        }
                    }
                    if kimi.isVisible {
                        KimiSectionDivider()
                            .padding(.top, 4)
                        ForEach(kimi.names, id: \.self) { name in
                            kimiCard(name)
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
                switch accountBanner {
                case .kimiExpiry(let name)?:
                    KimiExpiryBanner(name: name, current: kimi.expiries[name],
                                     onCancel: { accountBanner = nil },
                                     onSave: { expiry in
                                         kimi.setExpiry(expiry, for: name)
                                         accountBanner = nil
                                     })
                        .id(name)
                case .kimiRemoval(let name)?:
                    KimiRemovalBanner(name: name, onCancel: { accountBanner = nil },
                                      onDelete: {
                                          accountBanner = nil
                                          kimi.remove(name)
                                      })
                case .antigravityRemoval(let email)?:
                    AntigravityRemovalBanner(email: email, onCancel: { accountBanner = nil },
                                             onDelete: {
                                                 accountBanner = nil
                                                 antigravity.remove(email)
                                             })
                case nil:
                    EmptyView()
                }
                if addingProfile {
                    Divider()
                    AddProfileForm(actions: actions, kimi: kimi, antigravity: antigravity, isPresented: $addingProfile,
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
                                           stats: tokenStats, kimi: kimi, antigravity: antigravity))
        }
        .onDisappear {
            flyout.dismiss()
            tokenStats.confirmingClearAll = false
            accountBanner = nil
        }
        .onChange(of: profiles.profiles) { list in
            actions.update(with: list)
            flyout.rowsChanged(flyoutRows(claudeCode: list))
        }
        .onChange(of: chatgpt.profiles) { list in
            actions.update(withChatGPT: list)
            flyout.rowsChanged(flyoutRows(chatgpt: list))
        }
        .onChange(of: kimi.names) { names in
            // 删除了鼠标停着的 Kimi Code 账号时收起面板；账号没有了（如在钥匙串里删了）时收起它的确认条、编辑条
            flyout.rowsChanged(flyoutRows(kimi: names))
            switch accountBanner {
            case .kimiRemoval(let name)?, .kimiExpiry(let name)?:
                if !names.contains(name) { accountBanner = nil }
            default:
                break
            }
        }
        .onChange(of: antigravity.board.emails) { emails in
            // 删除了鼠标停着的 Antigravity 邮箱时收起面板
            flyout.rowsChanged(flyoutRows(antigravity: emails))
            if case .antigravityRemoval(let email)? = accountBanner, !emails.contains(email) { accountBanner = nil }
        }
    }

    /// 各段此刻全部有统计面板的行（StatsFlyoutHover.rowsChanged 要全部的行）；刚变了的那一段用 onChange 给的新值
    private func flyoutRows(claudeCode: [Profile]? = nil, chatgpt chatgptProfiles: [ChatGPTProfile]? = nil,
                            kimi kimiNames: [String]? = nil, antigravity emails: [String]? = nil) -> Set<StatsFlyoutRow> {
        StatsFlyoutRow.rows(claudeCode: claudeCode ?? profiles.profiles, chatgpt: chatgptProfiles ?? chatgpt.profiles,
                            kimi: kimiNames ?? kimi.names, antigravity: emails ?? antigravity.board.emails)
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

    /// 一张 Kimi Code 卡片（ADR 0007）：额度、套餐、有效期、复制 key、删除；停在上面弹出 Base URL 和模型列表
    private func kimiCard(_ name: String) -> some View {
        let row = StatsFlyoutRow.kimi(name)
        let sameAccount = KimiAccountInfo.sameAccount(as: name, names: kimi.names, infos: usage.kimiAccounts)
        let notice = kimi.copyNotice?.name == name ? kimi.copyNotice : nil
        return KimiCard(
            name: name, usage: usage.kimiUsage(name), now: usage.now,
            isRefreshing: usage.isRefreshingKimi(name),
            onRefresh: { usage.refreshKimi(name) },
            onDelete: { accountBanner = .kimiRemoval(name) },
            onCopyKey: { kimi.copyKey(name) },
            copyNotice: notice,
            expiry: kimi.expiries[name],
            onEditExpiry: { accountBanner = .kimiExpiry(name) },
            plan: usage.kimiAccounts[name]?.planName,
            sameAccountAs: sameAccount,
            isViewing: flyout.hover.row == row,
            onHover: { flyout.row(row, hovering: $0) })
        .statsFlyoutAnchor(row, controller: flyout)
    }

    /// 一张 Antigravity 卡片：额度、套餐、刷新、删除；停在上面弹出套餐和各组圆环（ticket 05）
    private func antigravityCard(_ card: AntigravityCard) -> some View {
        let row = StatsFlyoutRow.antigravity(card.email)
        return AntigravityAccountCard(
            card: card, now: usage.now,
            isRefreshing: antigravity.isRefreshing(card.email),
            onRefresh: { antigravity.refresh(card.email) },
            onDelete: { accountBanner = .antigravityRemoval(card.email) },
            notice: antigravity.notices[card.email],
            isViewing: flyout.hover.row == row,
            onHover: { flyout.row(row, hovering: $0) })
        .statsFlyoutAnchor(row, controller: flyout)
    }

    private var refreshAllButton: some View {
        Button {
            usage.refreshAll(profiles.profiles, chatgpt: chatgpt.profiles, kimi: kimi.names)
            antigravity.refreshAll()
        } label: {
            Group {
                if usage.isRefreshing || antigravity.isRefreshing {
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
        // 正在刷新，或者没有可刷新的账号（Claude Code、ChatGPT、Kimi Code 的账号都还在频率限制的等待期内，
        // ticket 12，也没有添加 Antigravity 账号）时不可用。Antigravity 没有等待期，添加过账号就能刷新
        .disabled(usage.isRefreshing || antigravity.isRefreshing
                  || !(usage.canRefreshAny(profiles.profiles, chatgpt: chatgpt.profiles, kimi: kimi.names)
                       || antigravity.isVisible))
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
