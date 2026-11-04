// 卡片右上角的"刷新这个账号的额度"按钮：刷新中显示转圈；频率限制的等待期内不可用，提示还要等几分钟。
// ChatGPT 档案卡片用（chatgpt-profiles ticket 07）；样式与 SwitchableProfileRow 里的刷新按钮相同。

import SwiftUI

struct UsageRefreshButton: View {
    let isRefreshing: Bool
    /// 频率限制还要等几分钟；不用等时为 nil
    let waitMinutes: Int?
    var size: CGFloat = 20
    let action: () -> Void

    var body: some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .frame(width: size, height: size)
        } else {
            Button(action: action) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: size, height: size)
            }
            .buttonStyle(.borderless)
            .disabled(waitMinutes != nil)
            .help(waitMinutes.map { Text("Too many requests. Try again in \($0) min.") }
                  ?? Text("Refresh usage for this account"))
            .accessibilityLabel(Text("Refresh usage for this account"))
        }
    }
}
