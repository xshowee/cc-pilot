// 面板里 Antigravity 一段前面的分割线（spec "界面"）：样式同 KimiSectionDivider，线上是 Antigravity 的图标。
// Antigravity 只显示额度，不是 Tool，所以不走 ToolSectionDivider / ToolIcon。
// 图标是 Contents/Resources/AntigravityIcon.png 与 @2x（scripts/make-icons.sh 从 Resources/Icons/antigravity.svg 生成）：
// 彩色图（透明底的多色 A 形），不是模板图，不着色；透明底不加 Kimi 那样的圆角描边。
// 不在 App 包里运行（找不到图标资源）时退回文字"Antigravity"。读屏读出"Antigravity"。

import SwiftUI

struct AntigravitySectionDivider: View {
    static let title = "Antigravity"
    /// 图标边长（pt），同 scripts/render-icons.swift 的 antigravityIconPoints
    static let iconPoints: CGFloat = 14

    private static let icon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "AntigravityIcon") else { return nil }
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
