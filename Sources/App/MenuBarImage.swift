// 把菜单栏的两行文字画成一张模板图片。
// MenuBarExtra 的 label 里放 VStack 两个 Text 会被压成一行，所以沿用 codex-pilot 的做法：
// 画成 22pt 高的模板图（isTemplate），由系统按菜单栏的明暗着色。

import AppKit

@MainActor
enum MenuBarImage {
    /// 档案名一行的最大宽度（pt），超出时中间截断
    static let maxWidth: CGFloat = 96

    private static var cachedLines: [String] = []
    private static var cachedImage: NSImage?

    static func image(top: String, bottom: String) -> NSImage {
        let text = [top, bottom]
        if text == cachedLines, let cachedImage { return cachedImage }

        let fonts = [NSFont.systemFont(ofSize: 10.5, weight: .medium),
                     NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)]
        let lines = zip(text, fonts).map { value, font in
            truncated(value, font: font, maxWidth: maxWidth)
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
        image.isTemplate = true
        cachedLines = text
        cachedImage = image
        return image
    }

    /// 超过 maxWidth 时从中间截断，保留开头和结尾（档案名常以序号或用途结尾）
    private static func truncated(_ value: String, font: NSFont, maxWidth: CGFloat) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
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
