// 面板里 Kimi Code 一段前面的分割线（ADR 0007）：样式同 ToolSectionDivider，线上是 Kimi 的图标。
// Kimi Code 只显示额度，不是 Tool（没有档案、不能切换），所以不走 ToolSectionDivider / ToolIcon。
// 图标是 Contents/Resources/KimiIcon.png 与 @2x（scripts/make-icons.sh 从 Resources/Icons/kimi.svg 生成）：
// 彩色图（黑底圆角方块、白色 K、蓝点），不是模板图，不着色；深色外观下加一圈细边，免得黑底融进背景。
// 不在 App 包里运行（找不到图标资源）时退回文字"Kimi Code"。读屏读出"Kimi Code"。

import SwiftUI

struct KimiSectionDivider: View {
    static let title = "Kimi Code"
    /// 图标边长（pt），同 scripts/render-icons.swift 的 kimiIconPoints
    static let iconPoints: CGFloat = 14

    private static let icon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "KimiIcon") else { return nil }
        image.size = NSSize(width: iconPoints, height: iconPoints)
        return image
    }()

    var body: some View {
        HStack(spacing: 8) {
            line
            mark
            line
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.title))
        .accessibilityAddTraits(.isHeader)
        .help(Text(verbatim: Self.title))
    }

    @ViewBuilder private var mark: some View {
        if let icon = Self.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: Self.iconPoints, height: Self.iconPoints)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.iconPoints * 5.5 / 24, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                )
        } else {
            Text(verbatim: Self.title)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .fixedSize()
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
    }
}
