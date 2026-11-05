// 工具图标（chatgpt-profiles ticket 03）：Claude Code / ChatGPT 的图标，面板分割线（ToolSectionDivider）、
// 菜单栏行首（ticket 11）与只显示一个工具时菜单栏两行文字的左侧共用这一个入口。
// 资源是 Contents/Resources/<Tool.iconResourceName(用途)>.png 与 @2x：按用途各一个尺寸
// （ToolIconResource.points：面板 12pt、菜单栏行首 10pt、菜单栏两行左侧 14pt，其中 Claude 15pt）的单色模板图（黑色 + 透明度），
// 由 scripts/make-icons.sh 从 Resources/Icons/*.svg 生成（见 Core 的 ToolIconResource）。
//
// 两种取法：
// - template：模板图。SwiftUI 里配 .renderingMode(.template) 按前景色着色；整张是模板图的菜单栏图片
//   （MenuBarImage.image 不着色时）里直接画它，由系统按菜单栏明暗着色。
// - tinted：着色后的图。菜单栏图片带颜色时（isTemplate = false）不会再被系统着色，里面的黑色模板图
//   在深色菜单栏上就看不见了，这时要用 tinted(tool, 用途, color: .labelColor)——与第一行文字同一取色方式，
//   动态色在绘制时按菜单栏当时的明暗取色。
// 不在 App 包里运行（找不到资源，如检查程序）时都返回 nil，调用方退回文字（Tool.displayName 或 "C"/"G"）。
// 图片的 accessibilityDescription 是工具名；SwiftUI 里仍要显式给 accessibilityLabel。

import AppKit

enum ToolIcon {
    typealias Use = ToolIconResource.Use

    /// 边长（pt）
    static func size(_ tool: Tool, _ use: Use) -> CGFloat {
        CGFloat(ToolIconResource.points(use, tool))
    }

    private struct Key: Hashable {
        let tool: Tool
        let use: Use
    }

    private static let templates: [Key: NSImage] = {
        var images: [Key: NSImage] = [:]
        for tool in Tool.allCases {
            for use in Use.allCases {
                guard let image = Bundle.main.image(forResource: tool.iconResourceName(use)) else { continue }
                image.isTemplate = true
                image.size = NSSize(width: size(tool, use), height: size(tool, use))
                image.accessibilityDescription = tool.displayName
                images[Key(tool: tool, use: use)] = image
            }
        }
        return images
    }()

    /// 模板图（黑色 + 透明度，isTemplate = true）
    static func template(_ tool: Tool, _ use: Use) -> NSImage? {
        templates[Key(tool: tool, use: use)]
    }

    /// 用 color 着色的图（isTemplate = false）。动态色（如 .labelColor）在每次绘制时按当时的外观取色
    static func tinted(_ tool: Tool, _ use: Use, color: NSColor) -> NSImage? {
        guard let base = template(tool, use) else { return nil }
        let image = NSImage(size: base.size, flipped: false) { rect in
            // 在透明图层里着色：sourceAtop 只涂图标本身，不影响合成图片里已经画在这块区域的东西
            let context = NSGraphicsContext.current?.cgContext
            context?.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            context?.endTransparencyLayer()
            return true
        }
        image.accessibilityDescription = tool.displayName
        return image
    }
}
