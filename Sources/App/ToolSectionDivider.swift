// 面板里两段档案（Claude Code、ChatGPT）之间的分割线，线上放工具的图标（ToolIcon，chatgpt-profiles ticket 03），
// 不另加标题。图标是模板图：Claude Code 用品牌橙色（ToolIcon.brandColor），ChatGPT 按次要文字的颜色着色、
// 深浅色外观都跟着系统走；读屏读出工具名。
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
                .frame(width: ToolIcon.size(tool, .panel), height: ToolIcon.size(tool, .panel))
                .foregroundColor(iconColor)
        } else {
            Text(verbatim: tool.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .fixedSize()
        }
    }

    private var iconColor: Color {
        ToolIcon.brandColor(tool).map { Color(nsColor: $0) } ?? .secondary
    }

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
    }
}
