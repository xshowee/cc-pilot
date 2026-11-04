// 面板里的 ChatGPT 档案卡片：在 ChatGPTProfileRow 外面包一层卡片底色和描边，样式与 SwitchableProfileRow 相同；
// 当前档案用强调色的淡底色和强调色头像标出。
// onSelect 为 nil 时（ticket 02：切换由 ticket 04 接上）卡片不可点击；ticket 04 传入切换动作即可点击切换。
// 刷新（07）、删除（06）等按钮以后叠在右上角，参照 SwitchableProfileRow。

import SwiftUI

struct ChatGPTProfileCard: View {
    let profile: ChatGPTProfile
    let isCurrent: Bool
    /// 点击卡片时的动作（切换为当前档案）；为 nil 时不可点击
    var onSelect: (() -> Void)? = nil

    @State private var hovering = false

    private static let cornerRadius: CGFloat = 10

    var body: some View {
        content
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
        let row = ChatGPTProfileRow(profile: profile, isCurrent: isCurrent)
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

    private var fill: Color {
        if isCurrent { return Color.accentColor.opacity(0.10) }
        return Color.primary.opacity(hovering && onSelect != nil ? 0.07 : 0.035)
    }
}
