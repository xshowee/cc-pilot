// 把 Resources/Icons/ 下的 SVG 渲染成 PNG。由 scripts/make-icons.sh 调用：
//   swift scripts/render-icons.swift <SVG 目录> <输出目录>
//
// 输出目录里得到：
//   AppIcon.iconset/icon_<N>x<N>[@2x].png   16–512pt 各 1x、@2x，交给 iconutil 合成 .icns
//     64 像素及以上用 AppIcon.svg；16、32 像素用 AppIcon-small.svg（去掉细节的简化版）
//   MenuBarIcon.png、MenuBarIcon@2x.png      菜单栏模板图，18pt（18、36 像素），来自 MenuBarIcon.svg
//
// SVG 由系统的 NSImage（CoreSVG）解析，不依赖任何需要安装的工具。
// 菜单栏图不做成 PDF：CoreSVG 画进 PDF 时会把 <mask>（镂空的提示符）按 24×24 栅格化，放大后发糊；
// 画进位图时则按实际像素栅格化，所以按两种倍率分别出 PNG。

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("用法：render-icons.swift <SVG 目录> <输出目录>\n".data(using: .utf8)!)
    exit(2)
}
let sources = URL(fileURLWithPath: args[1], isDirectory: true)
let output = URL(fileURLWithPath: args[2], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)

/// 菜单栏模板图的边长（pt）
let menuBarPoints = 18

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("render-icons: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func load(_ name: String) -> NSImage {
    let url = sources.appendingPathComponent(name)
    guard let image = NSImage(contentsOf: url), image.isValid else { fail("读不出 \(url.path)") }
    return image
}

/// 画成 points×scale 像素的 PNG；DPI 记为 72×scale，这样 @2x 图直接打开也是 points 大小
func writePNG(_ image: NSImage, points: Int, scale: Int, to url: URL) {
    let pixels = points * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { fail("无法创建 \(pixels) 像素的画布") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: points, height: points)
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("无法编码 \(url.lastPathComponent)") }
    do { try data.write(to: url) } catch { fail("写不了 \(url.path)：\(error)") }
}

do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch { fail("建不了 \(iconset.path)：\(error)") }

let full = load("AppIcon.svg"), small = load("AppIcon-small.svg")
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(points * scale <= 32 ? small : full, points: points, scale: scale,
                 to: iconset.appendingPathComponent(name))
    }
}

let glyph = load("MenuBarIcon.svg")
writePNG(glyph, points: menuBarPoints, scale: 1, to: output.appendingPathComponent("MenuBarIcon.png"))
writePNG(glyph, points: menuBarPoints, scale: 2, to: output.appendingPathComponent("MenuBarIcon@2x.png"))
