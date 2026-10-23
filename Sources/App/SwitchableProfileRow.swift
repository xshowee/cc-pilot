// 面板里可点击的档案行：在 ProfileRow 外面包一层，点击即切换为当前档案；
// 当前档案用强调色背景、左侧色条和"当前"标记醒目地标出。

import SwiftUI

struct SwitchableProfileRow: View {
    let profile: Profile
    let isCurrent: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isCurrent ? Color.accentColor : Color.clear)
                    .frame(width: 3)
                ProfileRow(profile: profile)
                if isCurrent {
                    Label("Current", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .padding(.trailing, 14)
                }
            }
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .help(isCurrent ? Text("This is the current profile") : Text("Switch to \(profile.name)"))
    }

    private var background: Color {
        if isCurrent { return Color.accentColor.opacity(0.14) }
        return hovering ? Color.primary.opacity(0.06) : Color.clear
    }
}
