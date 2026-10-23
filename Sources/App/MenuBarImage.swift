// 把菜单栏的两行文字画成一张图片。
// MenuBarExtra 的 label 里放 VStack 两个 Text 会被压成一行，所以沿用 codex-pilot 的做法：
// 画成 22pt 高的模板图（isTemplate），由系统按菜单栏的明暗着色。
// 额度一行需要着色时（ticket 12）不能用模板图：档案名用 labelColor（绘制时按菜单栏明暗取色），
// 额度用传入的颜色。

import AppKit

@MainActor
enum MenuBarImage {
    /// 档案名一行的最大宽度（pt），超出时中间截断
    static let maxWidth: CGFloat = 96

    private static var cachedKey: [AnyHashable] = []
    private static var cachedImage: NSImage?

    /// bottomColor 为 nil 时画成模板图（不着色）
    static func image(top: String, bottom: String, bottomColor: NSColor? = nil) -> NSImage {
        let key: [AnyHashable] = [top, bottom, bottomColor]
        if key == cachedKey, let cachedImage { return cachedImage }

        let fonts = [NSFont.systemFont(ofSize: 10.5, weight: .medium),
                     NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)]
        let colors: [NSColor] = bottomColor.map { [.labelColor, $0] } ?? [.black, .black]
        let lines = zip([top, bottom], zip(fonts, colors)).map { value, style in
            truncated(value, font: style.0, color: style.1, maxWidth: maxWidth)
        }
        let width = ceil(lines.map { $0.size().width }.max() ?? 0) + 4
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            for (index, line) in lines.enumerated() {
                let x = ((width - line.size().width) * 2).rounded() / 4
                // 字符串绘制自带基线留白，偏移一下让两行可见部分都落在 22pt 的状态栏里
                line.draw(at: NSPoint(x: x, y: index == 0 ? 10 : -2))
            }
            return true
        }
        image.isTemplate = bottomColor == nil
        cachedKey = key
        cachedImage = image
        return image
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
