// 面板里可点击的档案行：在 ProfileRow 外面包一层，点击即切换为当前档案；
// 当前档案用强调色背景、左侧色条和"当前"标记醒目地标出。
// 已登录的档案右侧有刷新按钮，刷新这个档案所在账号的额度（放在切换按钮外面，点它不会切换）；
// 频率限制的等待期内按钮不可用（ticket 12）。
// 有额度详情（按模型细分的周窗口、超额付费）时，刷新按钮下方还有展开按钮，展开后详情显示在行下方（ticket 13）。
// 鼠标移到行上时显示删除按钮（ticket 09，默认档案和当前档案不可用）；右键菜单里也有删除。

import SwiftUI

struct SwitchableProfileRow: View {
    let profile: Profile
    let isCurrent: Bool
    var usage: AccountUsage? = nil
    /// 界面时钟（UsageModel.now）
    var now = Date()
    var isRefreshing = false
    /// 刷新这个档案所在账号的额度；档案未登录时为 nil（不显示按钮）
    var onRefresh: (() -> Void)? = nil
    /// 删除入口：不能删除的原因（nil 表示可以删除）和删除动作；为 nil 时不显示删除入口
    var onDelete: (blocker: ProfileCommands.RemovalBlocker?, action: () -> Void)? = nil
    let onSelect: () -> Void

    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if expanded, hasDetails, let usage {
                UsageDetailsView(usage: usage, now: now)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 17)
                    .padding(.trailing, 14)
                    .padding(.bottom, 8)
            }
        }
        .background(background)
        .onHover { hovering = $0 }
    }

    private var hasDetails: Bool { UsageDetailsView.hasDetails(usage, now: now) }

    private var row: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(isCurrent ? Color.accentColor : Color.clear)
                        .frame(width: 3)
                    ProfileRow(profile: profile, usage: usage, now: now)
                    if isCurrent {
                        Label("Current", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .padding(.trailing, onRefresh == nil && !hasDetails && onDelete == nil ? 14 : 4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .help(isCurrent ? Text("This is the current profile") : Text("Switch to \(profile.name)"))

            if onRefresh != nil || hasDetails {
                VStack(spacing: 4) {
                    if let onRefresh {
                        refreshButton(onRefresh)
                    }
                    if hasDetails {
                        expandButton
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, onDelete == nil ? 10 : 2)
            }
            if let onDelete {
                DeleteProfileButton(profileName: profile.name, blocker: onDelete.blocker, action: onDelete.action)
                    .opacity(hovering ? 1 : 0)
                    .padding(.top, 8)
                    .padding(.trailing, 10)
            }
        }
        .contextMenu {
            if let onDelete {
                Button("Delete “\(profile.name)”…", action: onDelete.action)
                    .disabled(onDelete.blocker != nil)
            }
        }
    }

    private var expandButton: some View {
        Button {
            expanded.toggle()
        } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(expanded ? Text("Hide usage details") : Text("Show usage details"))
        .accessibilityLabel(expanded ? Text("Hide usage details") : Text("Show usage details"))
    }

    @ViewBuilder private func refreshButton(_ action: @escaping () -> Void) -> some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
        } else {
            Button(action: action) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(waitMinutes != nil)
            .help(waitMinutes.map { Text("Too many requests. Try again in \($0) min.") }
                  ?? Text("Refresh usage for this account"))
            .accessibilityLabel(Text("Refresh usage for this account"))
        }
    }

    /// 频率限制还要等几分钟；不用等时为 nil
    private var waitMinutes: Int? {
        usage?.waitRemaining(now: now).map(UsageDisplay.waitMinutes)
    }

    private var background: Color {
        if isCurrent { return Color.accentColor.opacity(0.14) }
        return hovering ? Color.primary.opacity(0.06) : Color.clear
    }
}
