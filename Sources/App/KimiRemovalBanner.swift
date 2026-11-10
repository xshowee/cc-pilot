// 面板里删除 Kimi Code 账号的确认条（ADR 0007）：点卡片上的删除按钮后出现在底栏上方，样式同 ClearAllBanner。
// 确认后从钥匙串移除这个账号的 API key；Claude、ChatGPT 的删除在终端里由 ccp 确认，Kimi Code 没有 ccp 命令。

import SwiftUI

struct KimiRemovalBanner: View {
    let name: String
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "trash")
                .foregroundColor(.accentColor)
            Text("Delete “\(name)” and remove its API key from the keychain?")
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
