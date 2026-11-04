// 档案行上的删除入口（ticket 09）。默认档案和当前档案不能删除：按钮不可用，提示说明原因。
// 点击后由 ProfileActionsModel 打开终端执行 ccp rm（确认、登出都在终端里由 ccp 完成）。
// ChatGPT 档案卡片也用它（chatgpt-profiles ticket 06，执行 ccp chatgpt rm）；launchd 仍指向的 ChatGPT 档案也不能删除。

import SwiftUI

struct DeleteProfileButton: View {
    let profileName: String
    /// 不能删除的原因；可以删除时为 nil
    let blocker: ProfileCommands.RemovalBlocker?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(blocker != nil)
        .help(help)
        .accessibilityLabel(Text("Delete “\(profileName)”…"))
    }

    private var help: Text {
        switch blocker {
        case .defaultProfile?: return Text("The default profile can’t be deleted")
        case .currentProfile?: return Text("The current profile can’t be deleted. Switch to another profile first.")
        case .launchdProfile?:
            return Text("Apps opened from the Dock still use this profile. Switch profiles again to update it first.")
        case nil: return Text("Delete “\(profileName)”…")
        }
    }
}
