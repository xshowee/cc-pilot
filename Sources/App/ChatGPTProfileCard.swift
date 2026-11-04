// 面板里的 ChatGPT 档案卡片：在 ChatGPTProfileRow 外面包一层卡片底色和描边，样式与 SwitchableProfileRow 相同；
// 当前档案用强调色的淡底色和强调色头像标出。
// onSelect 为 nil 时（ticket 02：切换由 ticket 04 接上）卡片不可点击；ticket 04 传入切换动作即可点击切换。
// 右上角的按钮叠在卡片上面（点它们不会切换），参照 SwitchableProfileRow：已登录 ChatGPT 的档案有刷新按钮
// （ticket 07，onRefresh 为 nil 时不显示），删除（06）以后加在它左边。

import SwiftUI

struct ChatGPTProfileCard: View {
    let profile: ChatGPTProfile
    let isCurrent: Bool
    /// 点击卡片时的动作（切换为当前档案）；为 nil 时不可点击
    var onSelect: (() -> Void)? = nil
    /// 这个档案所在账号的额度状态（ticket 07）
    var usage: AccountUsage? = nil
    /// 界面时钟（UsageModel.now）
    var now = Date()
    /// 最近一次刷新时响应里的套餐
    var reportedPlan: String? = nil
    var isRefreshing = false
    /// 刷新这个档案所在账号的额度；档案没有账号时为 nil（不显示按钮）
    var onRefresh: (() -> Void)? = nil

    @State private var hovering = false

    private static let cornerRadius: CGFloat = 10
    private static let buttonSize: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            if let onRefresh {
                UsageRefreshButton(isRefreshing: isRefreshing,
                                   waitMinutes: usage?.waitRemaining(now: now).map(UsageDisplay.waitMinutes),
                                   size: Self.buttonSize, action: onRefresh)
                    .foregroundColor(.secondary)
                    // 与头像（30pt，距顶 12pt）垂直居中
                    .padding(.top, 12 + (30 - Self.buttonSize) / 2)
                    .padding(.trailing, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var content: some View {
        let row = ChatGPTProfileRow(profile: profile, isCurrent: isCurrent, usage: usage, now: now,
                                    reportedPlan: reportedPlan, headerTrailingInset: buttonsWidth)
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        if let onSelect {
            Button(action: onSelect) { row }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .help(isCurrent ? "" : String(localized: "Switch to \(profile.name)"))
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
        }
    }

    private var buttonsWidth: CGFloat { onRefresh == nil ? 0 : Self.buttonSize + 2 }

    private var fill: Color {
        if isCurrent { return Color.accentColor.opacity(0.10) }
        return Color.primary.opacity(hovering && onSelect != nil ? 0.07 : 0.035)
    }
}
