// 把菜单栏的两行文字画成一张图片。
// MenuBarExtra 的 label 里放 VStack 两个 Text 会被压成一行，所以沿用 codex-pilot 的做法：
// 画成 22pt 高的模板图（isTemplate），由系统按菜单栏的明暗着色。
// 额度一行需要着色时（ticket 12）不能用模板图：档案名用 labelColor（绘制时按菜单栏明暗取色），
// 额度用传入的颜色（过期灰也是动态色，同样在绘制时按菜单栏明暗取浅色/深色那个，ticket 26）。
// 只显示一个工具时两行文字的左侧是这个工具的图标（ToolIcon 的 .menuBarSummary 规格，14pt，Claude 15pt），竖直方向对准两行文字的中线，
// 一眼看出说的是 Claude Code 还是 ChatGPT（Pro、Team 等套餐名两边都有）；两行文字仍在图标右侧的区域里互相居中。
// 着色规则同下面两个工具时：整张是模板图时画模板图，否则画 tinted(..., color: .labelColor)。找不到图标时只画文字。
// "只显示图标"模式用的图标（icon）也放在这里。
// 两个工具都显示时（chatgpt-profiles ticket 11）每行一个工具：行首是工具图标（ToolIcon 的 .menuBar 规格，10pt 原尺寸），
// 后面是 5 小时剩余，两行各自着色（image(toolRows:)）。整张都不着色时是模板图，图标画模板图；
// 有一行着色时整张不是模板图，图标必须画 tinted(..., color: .labelColor)，否则深色菜单栏上看不见。
// 找不到图标（不在 App 包里运行）时行首退回文字 "C" / "G"。

import AppKit

@MainActor
enum MenuBarImage {
    /// 第一行（MenuBarSummary.titleLine）的最大宽度（pt），超出时中间截断
    static let maxWidth: CGFloat = 96

    /// "只显示图标"模式的图标（ticket 17）：Resources/MenuBarIcon.png 与 @2x，18pt 的单色模板图，
    /// 由系统按菜单栏明暗着色。由 scripts/make-icons.sh 从 Resources/Icons/MenuBarIcon.svg 生成。
    /// 不在 App 包里运行（找不到资源）时退回 SF Symbol。
    static let icon: NSImage = {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: nil)
            ?? NSImage()
        image.isTemplate = true
        return image
    }()

    private static var cachedKey: [AnyHashable] = []
    private static var cachedImage: NSImage?

    /// 两行文字左侧画 tool 的图标。bottomColor 为 nil 时画成模板图（不着色）
    static func image(tool: Tool, top: String, bottom: String, bottomColor: NSColor? = nil) -> NSImage {
        let key: [AnyHashable] = ["summary", tool, top, bottom, bottomColor]
        if key == cachedKey, let cachedImage { return cachedImage }

        let fonts = [NSFont.systemFont(ofSize: 10.5, weight: .medium),
                     NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)]
        let colors: [NSColor] = bottomColor.map { [.labelColor, $0] } ?? [.black, .black]
        let lines = zip([top, bottom], zip(fonts, colors)).map { value, style in
            truncated(value, font: style.0, color: style.1, maxWidth: maxWidth)
        }
        // 字符串绘制自带基线留白，偏移一下让两行可见部分都落在 22pt 的状态栏里
        let lineY: [CGFloat] = [10, -2]
        let icon = bottomColor == nil ? ToolIcon.template(tool, .menuBarSummary)
                                      : ToolIcon.tinted(tool, .menuBarSummary, color: .labelColor)
        let iconSize = ToolIcon.size(tool, .menuBarSummary)
        let iconWidth = icon == nil ? 0 : iconSize + 4
        let textWidth = ceil(lines.map { $0.size().width }.max() ?? 0)
        let width = ceil(iconWidth + textWidth) + 4
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            if let icon {
                // 两行文字可见部分的中线：第二行的基线与第一行大写字母顶端之间
                let bottomBaseline = lineY[1] - fonts[1].descender
                let topCapLine = lineY[0] - fonts[0].descender + fonts[0].capHeight
                let iconY = (((bottomBaseline + topCapLine) / 2 - iconSize / 2) * 2).rounded() / 2
                icon.draw(in: NSRect(x: 2, y: min(max(iconY, 0), 22 - iconSize), width: iconSize, height: iconSize))
            }
            for (index, line) in lines.enumerated() {
                let x = 2 + iconWidth + ((textWidth - line.size().width) * 2).rounded() / 4
                line.draw(at: NSPoint(x: x, y: lineY[index]))
            }
            return true
        }
        image.isTemplate = bottomColor == nil
        cachedKey = key
        cachedImage = image
        return image
    }

    /// 两个工具都显示时的一行：工具、额度文字（MenuBarToolLine.quotaLine）、颜色（nil 表示不着色）
    struct ToolRow: Hashable {
        let tool: Tool
        let text: String
        let color: NSColor?
    }

    /// 每行一个工具（上下两行）。所有行的 color 都为 nil 时画成模板图
    static func image(toolRows rows: [ToolRow]) -> NSImage {
        let key: [AnyHashable] = ["tools"] + rows.flatMap { [$0.tool, $0.text, $0.color] as [AnyHashable] }
        if key == cachedKey, let cachedImage { return cachedImage }

        let isTemplate = rows.allSatisfy { $0.color == nil }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let letterFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let iconSize = rows.map { ToolIcon.size($0.tool, .menuBar) }.max() ?? 0
        let gap: CGFloat = 3
        let drawn: [(icon: NSImage?, text: NSAttributedString)] = rows.map { row in
            let icon = isTemplate ? ToolIcon.template(row.tool, .menuBar)
                                  : ToolIcon.tinted(row.tool, .menuBar, color: .labelColor)
            let text = NSMutableAttributedString()
            if icon == nil {
                text.append(NSAttributedString(string: fallbackLetter(row.tool) + " ", attributes: [
                    .font: letterFont, .foregroundColor: isTemplate ? NSColor.black : .labelColor]))
            }
            text.append(NSAttributedString(string: row.text, attributes: [
                .font: font, .foregroundColor: isTemplate ? NSColor.black : (row.color ?? .labelColor)]))
            return (icon, text)
        }
        let rowWidths = drawn.map { ($0.icon == nil ? 0 : iconSize + gap) + $0.text.size().width }
        let width = ceil(rowWidths.max() ?? 0) + 4
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            for (index, row) in drawn.enumerated() {
                // 与 image(top:bottom:) 同样的两行位置；图标左对齐成一列，竖直方向对准数字的中线
                let y: CGFloat = index == 0 ? 10 : -2
                var x: CGFloat = 2
                if let icon = row.icon {
                    let baseline = y - font.descender
                    let iconY = ((baseline + font.capHeight / 2 - iconSize / 2) * 2).rounded() / 2
                    icon.draw(in: NSRect(x: x, y: min(max(iconY, 0), 22 - iconSize), width: iconSize, height: iconSize))
                    x += iconSize + gap
                }
                row.text.draw(at: NSPoint(x: x, y: y))
            }
            return true
        }
        image.isTemplate = isTemplate
        cachedKey = key
        cachedImage = image
        return image
    }

    /// 找不到工具图标时行首的文字
    private static func fallbackLetter(_ tool: Tool) -> String {
        switch tool {
        case .claudeCode: return "C"
        case .chatgpt: return "G"
        }
    }

    /// 超过 maxWidth 时从中间截断，保留开头和结尾（档案名常以序号或用途结尾）
    private static func truncated(_ value: String, font: NSFont, color: NSColor,
                                  maxWidth: CGFloat) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        func make(_ s: String) -> NSAttributedString { NSAttributedString(string: s, attributes: attributes) }
        let full = make(value)
        guard full.size().width > maxWidth else { return full }
        let chars = Array(value)
        var keep = chars.count - 1
        while keep > 1 {
            let head = chars.prefix((keep + 1) / 2), tail = chars.suffix(keep / 2)
            let candidate = make(String(head) + "…" + String(tail))
            if candidate.size().width <= maxWidth { return candidate }
            keep -= 1
        }
        return make(String(chars.prefix(1)) + "…")
    }
}
