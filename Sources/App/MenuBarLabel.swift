// 菜单栏上显示的内容：默认两行（当前档案名、额度），打开"只显示图标"后只显示图标。
// 额度一行的内容来自 MenuBarSummary.quotaLine（没刷新过时是"—"）。

import SwiftUI

struct MenuBarLabel: View {
    let summary: MenuBarSummary
    let iconOnly: Bool

    var body: some View {
        Group {
            if iconOnly {
                Image(systemName: "person.2.circle")
            } else {
                Image(nsImage: MenuBarImage.image(top: summary.profileName, bottom: summary.quotaLine))
                    .renderingMode(.template)
            }
        }
        .accessibilityLabel(Text("CC Pilot"))
        .accessibilityValue(Text("Current profile: \(summary.profileName)"))
        .help(Text("Current profile: \(summary.profileName)"))
    }
}
