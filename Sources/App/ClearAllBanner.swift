// 面板里"清空全部账号"的确认条（token-usage ticket 07）：从设置菜单进入，确认后清空所有账号的累计 Token 用量
// （起算点移到此刻，不碰 Claude Code 的任何文件）。样式同 PendingChangeBanner，不弹系统对话框。

import SwiftUI

struct ClearAllBanner: View {
    let onCancel: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "trash")
                .foregroundColor(.accentColor)
            Text("Clear cumulative token usage for all accounts?")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .controlSize(.small)
            Button("Clear", action: onClear)
                .controlSize(.small)
                .foregroundColor(StatusColor.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}
