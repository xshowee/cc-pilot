// 菜单栏上显示的内容（显示哪些工具由 Core 的 MenuBarContent 决定）：
// - 只显示一个工具：左侧是这个工具的图标，右侧两行（第一行见 MenuBarSummary.titleLine：Claude 订阅等级 / ChatGPT 套餐，
//   不知道时是档案名；额度）；
// - 两个工具都显示（chatgpt-profiles ticket 11）：每行一个工具，`[图标] N%`；
// - 打开"只显示图标"后只显示图标。
// 悬停提示和读屏说出当前档案名（两个工具时两个都说）。
// 额度的文字来自 quotaLine（没刷新过时是"—"，已过重置时间是"已重置"），颜色与列表同一规则
// （quotaTint：剩余百分比的阈值颜色、超过 30 分钟变灰；没有数字时不着色）。

import SwiftUI

struct MenuBarLabel: View {
    let content: MenuBarContent
    let iconOnly: Bool

    var body: some View {
        Group {
            if iconOnly {
                Image(nsImage: MenuBarImage.icon)
                    .renderingMode(.template)
            } else {
                let image = self.image
                // 不着色时用模板图，由系统按菜单栏明暗着色；着色时保留颜色
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
            }
        }
        .accessibilityLabel(Text("CC Pilot"))
        .accessibilityValue(description)
        .help(description)
    }

    private var image: NSImage {
        let resetText = String(localized: "Reset")
        switch content {
        case .single(let summary):
            return MenuBarImage.image(tool: summary.tool,
                                      top: summary.titleLine(tierName: AccountText.tierName,
                                                             planName: ChatGPTAccountText.planName),
                                      bottom: summary.quotaLine(resetText: resetText),
                                      bottomColor: summary.quotaTint.nsColor)
        case .twoTools(let first, let second):
            return MenuBarImage.image(toolRows: [first, second].map {
                MenuBarImage.ToolRow(tool: $0.tool, text: $0.quotaLine(resetText: resetText), color: $0.quotaTint.nsColor)
            })
        }
    }

    private var description: Text {
        switch content {
        case .single(let summary) where summary.tool == .chatgpt:
            return Text("Current ChatGPT profile: \(summary.profileName)")
        case .single(let summary):
            return Text("Current profile: \(summary.profileName)")
        case .twoTools(let claude, let chatgpt):
            return Text("Current profiles: Claude Code \(claude.profileName), ChatGPT \(chatgpt.profileName)")
        }
    }
}
