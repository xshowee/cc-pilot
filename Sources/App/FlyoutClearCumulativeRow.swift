// 侧边统计面板底部"清空累计"行（token-usage ticket 07）：显示起算点，点击后就地二次确认；
// 切换账号时通过 resetKey 自动退出确认状态，与 StatsFlyoutView、AntigravityFlyoutView 共用。

import SwiftUI

/// 面板底部"清空累计"行：显示起算点，点击后在原地二次确认；切换账号时自动退出确认状态
struct FlyoutClearCumulativeRow: View {
    let title: String
    let origin: Date?
    let canClear: Bool
    let now: Date
    let resetKey: String
    let onClear: () -> Void

    @State private var confirmingClear = false

    var body: some View {
        HStack(spacing: 6) {
            if confirmingClear {
                Text("Clear cumulative usage for \(title)?")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Cancel") { confirmingClear = false }
                    .controlSize(.small)
                Button("Clear") {
                    confirmingClear = false
                    onClear()
                }
                .controlSize(.small)
                .foregroundColor(StatusColor.red)
            } else {
                if let origin {
                    Text("Cumulative since \(TokenUsageDisplay.origin(origin, now: now))")
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Clear Cumulative") { confirmingClear = true }
                    .controlSize(.small)
                    .disabled(!canClear)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .onChange(of: resetKey) { _ in confirmingClear = false }
    }
}
