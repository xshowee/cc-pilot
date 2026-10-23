// 点击菜单栏图标后弹出的面板：标题与"刷新全部"、档案列表（点击即切换，可单独刷新额度、删除）、
// 添加档案（ticket 09）、菜单栏显示设置、底部操作。
// 打开面板只重读档案列表和当前档案，不刷新额度。

import SwiftUI

struct PanelView: View {
    @ObservedObject var profiles: ProfileListModel
    @ObservedObject var current: CurrentProfileModel
    @ObservedObject var usage: UsageModel
    @ObservedObject var actions: ProfileActionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Profiles")
                    .font(.headline)
                Spacer()
                refreshAllButton
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
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
                            )
                        ) {
                            current.switchTo(profile.name)
                        }
                        if profile.id != profiles.profiles.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)

            if let pending = actions.pending {
                PendingChangeBanner(change: pending) { actions.dismissPending() }
            }
            Divider()
            AddProfileForm(actions: actions)
            Divider()
            MenuBarIconOnlyToggle()
            Divider()
            PanelFooter()
        }
        .frame(width: 320)
        .onAppear { profiles.reload(); current.reload(); actions.update(with: profiles.profiles) }
        .onChange(of: profiles.profiles) { actions.update(with: $0) }
    }

    private var refreshAllButton: some View {
        Button {
            usage.refreshAll(profiles.profiles)
        } label: {
            if usage.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Label("Refresh All", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        // 正在刷新，或每个账号都还在频率限制的等待期内（ticket 12）时不可用
        .disabled(usage.isRefreshing || !usage.canRefreshAny(profiles.profiles))
        .help(Text("Refresh usage for all accounts"))
    }
}
