// 菜单栏上显示的内容：默认两行（第一行见 MenuBarSummary.titleLine；额度），
// 打开"只显示图标"后只显示图标。悬停提示和读屏仍说出当前档案名。
// 额度一行的文字来自 MenuBarSummary.quotaLine（没刷新过时是"—"，已过重置时间是"已重置"），
// 颜色与列表同一规则（MenuBarSummary.quotaTint：severity、超过 30 分钟变灰；没有时不着色）。

import SwiftUI

struct MenuBarLabel: View {
    let summary: MenuBarSummary
    let iconOnly: Bool

    var body: some View {
        Group {
            if iconOnly {
                Image(nsImage: MenuBarImage.icon)
                    .renderingMode(.template)
            } else {
                let color = summary.quotaTint.nsColor
                Image(nsImage: MenuBarImage.image(top: summary.titleLine(tierName: AccountText.tierName),
                                                  bottom: summary.quotaLine(resetText: String(localized: "Reset")),
                                                  bottomColor: color))
                    // 不着色时用模板图，由系统按菜单栏明暗着色；着色时保留颜色
                    .renderingMode(color == nil ? .template : .original)
            }
        }
        .accessibilityLabel(Text("CC Pilot"))
        .accessibilityValue(Text("Current profile: \(summary.profileName)"))
        .help(Text("Current profile: \(summary.profileName)"))
    }
}
