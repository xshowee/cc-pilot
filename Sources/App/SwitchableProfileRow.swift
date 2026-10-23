// 面板里可点击的档案行：在 ProfileRow 外面包一层，点击即切换为当前档案；
// 当前档案用强调色背景、左侧色条和"当前"标记醒目地标出。
// 已登录的档案右侧有刷新按钮，刷新这个档案所在账号的额度（放在切换按钮外面，点它不会切换）；
// 频率限制的等待期内按钮不可用（ticket 12）。

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
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
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
                            .padding(.trailing, onRefresh == nil ? 14 : 4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .help(isCurrent ? Text("This is the current profile") : Text("Switch to \(profile.name)"))

            if let onRefresh {
                refreshButton(onRefresh)
                    .padding(.top, 8)
                    .padding(.trailing, 10)
            }
        }
        .background(background)
        .onHover { hovering = $0 }
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
