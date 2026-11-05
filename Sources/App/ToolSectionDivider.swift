// 面板里两段档案（Claude Code、ChatGPT）之间的分割线，线上放工具的图标（ToolIcon，chatgpt-profiles ticket 03），
// 不另加标题。图标是模板图：Claude Code 用品牌橙色（#D97757），ChatGPT 按次要文字的颜色着色、深浅色外观都跟着
// 系统走；读屏读出工具名。菜单栏里两个图标都保持单色（ticket 11，macOS 菜单栏的惯例；用户 2026-11-05 决定）。
// 不在 App 包里运行（找不到图标资源）时退回工具名的文字。

import SwiftUI

struct ToolSectionDivider: View {
    let tool: Tool

    var body: some View {
        HStack(spacing: 8) {
            line
            mark
            line
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tool.displayName))
        .accessibilityAddTraits(.isHeader)
        .help(Text(verbatim: tool.displayName))
    }

    @ViewBuilder private var mark: some View {
        if let icon = ToolIcon.template(tool, .panel) {
            Image(nsImage: icon)
                .renderingMode(.template)
                .resizable()
                .frame(width: ToolIcon.size(.panel), height: ToolIcon.size(.panel))
                .foregroundColor(iconColor)
        } else {
            Text(verbatim: tool.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .fixedSize()
        }
    }

    private var iconColor: Color {
        switch tool {
        case .claudeCode: return Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .chatgpt: return .secondary
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
    }
}
