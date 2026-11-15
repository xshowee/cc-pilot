// 面板里删除 Antigravity 卡片的确认条（spec "界面"）：点卡片上的删除按钮后出现在底栏上方，样式同 KimiRemovalBanner。
// 确认后从看板和本机存储删掉这个邮箱的快照；Antigravity 里的登录不受影响，之后再读到同一邮箱也不会重新出现，要再手动添加。

import SwiftUI

struct AntigravityRemovalBanner: View {
    let email: String
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "trash")
                .foregroundColor(.accentColor)
            Text("Delete “\(email)” and its saved usage?")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .controlSize(.small)
            Button("Delete", action: onDelete)
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
