// 面板顶部的一行提示（ticket 25）：未接入 zsh 时，面板切换只改写当前档案记录，终端里的 claude 不读它，
// 看起来切换了其实没生效。提示说明这一点，并带"接入…"按钮（走 ShellIntegrationModel.connectWithConsent()）。
// 是否显示由 ShellIntegrationModel.showsNotConnectedHint 决定；样式与 PendingChangeBanner 相同（与档案卡片同宽的圆角底色），
// 不占档案行的宽度。不用橙色（橙色只留给额度"偏紧"，ticket 24）。

import SwiftUI

struct ShellIntegrationBanner: View {
    let onSetUp: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.accentColor)
            Text("zsh isn’t set up, so switching here won’t affect claude in Terminal.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Set Up…", action: onSetUp)
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .fixedSize()
                .help(Text("Set up zsh so that claude in Terminal uses the profile selected here"))
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
