// 面板里的一行提示（ticket 09）：已在终端里开始添加或删除档案，提示用户去终端完成。
// 完成后（新档案已登录、或档案已被删除）由 ProfileActionsModel 自动清除；用户也可以手动关掉。

import SwiftUI

struct PendingChangeBanner: View {
    let change: ProfileCommands.PendingChange
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal")
                .foregroundColor(.accentColor)
            message
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(Text("Dismiss"))
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private var message: Text {
        switch change {
        case .adding(let name):
            return Text("Sign in to “\(name)” in the Terminal window. It will show as signed in here when you’re done.")
        case .removing(let name):
            return Text("Follow the steps in the Terminal window to sign out of and delete “\(name)”.")
        }
    }
}
