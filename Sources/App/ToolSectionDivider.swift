// 面板里两段档案（Claude Code、ChatGPT）之间的分割线，线上放工具的标识。
// 官方图标素材到位（chatgpt-profiles ticket 03）之前，用工具名的文字代替。

import SwiftUI

struct ToolSectionDivider: View {
    let tool: Tool

    var body: some View {
        HStack(spacing: 8) {
            line
            Text(verbatim: tool.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .fixedSize()
            line
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
    }
}
