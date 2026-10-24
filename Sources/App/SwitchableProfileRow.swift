// 面板里可点击的档案卡片：在 ProfileRow 外面包一层，点击即切换为当前档案；
// 当前档案用强调色的淡底色、强调色头像和"当前"标记标出（标记在 ProfileRow 的档案名后面，ticket 18）。
// 统计面板正在显示的那一行用强调色的粗描边标出（token-usage：参照 iStat），描边只留给它，所以当前档案不再描强调色边。
// 强调色随系统外观（浅色 / 深色）和用户设置的强调色变化。
// 卡片右上角是按钮（叠在切换按钮上面，点它们不会切换）：
//   已登录的档案有刷新按钮，刷新这个档案所在账号的额度；频率限制的等待期内不可用（ticket 12）。
//   有额度详情（按模型细分的周窗口、超额付费）时有展开按钮（ticket 13）；展开后详情显示在
//   卡片里主窗口之后、获取时间之前（ticket 19），点详情也会切换档案。
//   鼠标移到卡片上时显示删除按钮（ticket 09，默认档案和当前档案不可用）；右键菜单里也有删除。
// 鼠标进出卡片时通知 onHover（token-usage ticket 07：停在账号行上时左侧弹出统计面板）。

import SwiftUI

struct SwitchableProfileRow: View {
    let profile: Profile
    let isCurrent: Bool
    /// 统计面板正在显示这一行
    var isViewing = false
    var usage: AccountUsage? = nil
    /// 界面时钟（UsageModel.now）
    var now = Date()
    var isRefreshing = false
    /// 刷新这个档案所在账号的额度；档案未登录时为 nil（不显示按钮）
    var onRefresh: (() -> Void)? = nil
    /// 删除入口：不能删除的原因（nil 表示可以删除）和删除动作；为 nil 时不显示删除入口
    var onDelete: (blocker: ProfileCommands.RemovalBlocker?, action: () -> Void)? = nil
    /// 鼠标进出卡片（统计面板用）
    var onHover: ((Bool) -> Void)? = nil
    let onSelect: () -> Void

    @State private var hovering = false
    @State private var expanded = false

    private static let buttonSize: CGFloat = 20
    private static let cornerRadius: CGFloat = 10

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                ProfileRow(profile: profile, isCurrent: isCurrent, usage: usage, now: now,
                           expanded: expanded && hasDetails, headerTrailingInset: buttonsWidth)
                    .padding(12)
                    .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .help(isCurrent ? Text("This is the current profile") : Text("Switch to \(profile.name)"))

            buttons
                // 与头像（30pt，距顶 12pt）垂直居中
                .padding(.top, 12 + (30 - Self.buttonSize) / 2)
                .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(stroke, lineWidth: isViewing ? 2 : 1)
        )
        .onHover {
            hovering = $0
            onHover?($0)
        }
        .contextMenu {
            if let onDelete {
                Button("Delete “\(profile.name)”…", action: onDelete.action)
                    .disabled(onDelete.blocker != nil)
            }
        }
    }

    private var hasDetails: Bool { UsageDetailsView.hasDetails(usage, now: now) }

    private var buttonCount: Int {
        (onDelete == nil ? 0 : 1) + (hasDetails ? 1 : 0) + (onRefresh == nil ? 0 : 1)
    }

    private var buttonsWidth: CGFloat {
        buttonCount == 0 ? 0 : CGFloat(buttonCount) * (Self.buttonSize + 2)
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            if let onDelete {
                DeleteProfileButton(profileName: profile.name, blocker: onDelete.blocker, action: onDelete.action)
                    .opacity(hovering ? 1 : 0)
            }
            if hasDetails {
                expandButton
            }
            if let onRefresh {
                refreshButton(onRefresh)
            }
        }
        .foregroundColor(.secondary)
    }

    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
        }
        .buttonStyle(.borderless)
        .help(expanded ? Text("Hide usage details") : Text("Show usage details"))
        .accessibilityLabel(expanded ? Text("Hide usage details") : Text("Show usage details"))
    }

    @ViewBuilder private func refreshButton(_ action: @escaping () -> Void) -> some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
        } else {
            Button(action: action) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
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

    private var fill: Color {
        if isCurrent { return Color.accentColor.opacity(0.10) }
        return Color.primary.opacity(hovering ? 0.07 : 0.035)
    }

    private var stroke: Color {
        isViewing ? Color.accentColor : Color.primary.opacity(0.06)
    }
}
