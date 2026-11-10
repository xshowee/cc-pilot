// 把 Resources/Icons/ 下的 SVG 渲染成 PNG。由 scripts/make-icons.sh 调用：
//   swift scripts/render-icons.swift <SVG 目录> <输出目录>
//
// 输出目录里得到：
//   AppIcon.iconset/icon_<N>x<N>[@2x].png   16–512pt 各 1x、@2x，交给 iconutil 合成 .icns
//     64 像素及以上用 AppIcon.svg；16、32 像素用 AppIcon-small.svg（去掉细节的简化版）
//   MenuBarIcon.png、MenuBarIcon@2x.png      菜单栏模板图，18pt（18、36 像素），来自 MenuBarIcon.svg
//   ClaudeIcon.png、ChatGPTIcon.png 与 @2x   工具图标（chatgpt-profiles ticket 03），来自 claude.svg、chatgpt.svg：
//     面板分割线用，12pt（12、24 像素）
//   ClaudeMenuBarIcon.png、ChatGPTMenuBarIcon.png 与 @2x   同上，菜单栏行首用，ChatGPT 10pt（10、20 像素），
//     Claude 11pt（11、22 像素）
//   ClaudeMenuBarSummaryIcon.png、ChatGPTMenuBarSummaryIcon.png 与 @2x   同上，只显示一个工具时
//     菜单栏两行文字的左侧用，ChatGPT 14pt（14、28 像素），Claude 15pt（15、30 像素）
//     名字与边长须与 Core 的 Tool.iconResourceName、ToolIconResource.points 一致（tests/swift/AppIconChecks.swift 核对）。
//     素材本身是灰色，出图时只保留形状（透明度）、涂成黑色，做成与 MenuBarIcon 一样的单色模板图。
//   KimiIcon.png 与 @2x   Kimi Code 一段的分割线用（ADR 0007），来自 kimi.svg，14pt（14、28 像素）。
//     彩色图（黑底圆角方块、白色 K、蓝点），不是模板图：原样出图，不涂黑。Kimi Code 不是 Tool，只有这一个用途。
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
/// Kimi Code 图标的边长（pt），同 App 的 KimiSectionDivider.iconPoints
let kimiIconPoints = 14
/// 工具图标：资源名后缀与各工具的边长（pt），同 Core 的 Tool.iconResourceName、ToolIconResource.points
let toolIconSizes: [(String, [String: Int])] = [
    ("Icon", ["Claude": 12, "ChatGPT": 12]),
    ("MenuBarIcon", ["Claude": 11, "ChatGPT": 10]),
    ("MenuBarSummaryIcon", ["Claude": 15, "ChatGPT": 14]),
]

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
/// monochrome 为 true 时画完把所有不透明的地方涂成黑色（只保留透明度），用于模板图
func writePNG(_ image: NSImage, points: Int, scale: Int, monochrome: Bool = false, to url: URL) {
    let pixels = points * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { fail("无法创建 \(pixels) 像素的画布") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    image.draw(in: canvas)
    if monochrome {
        NSColor.black.set()
        canvas.fill(using: .sourceAtop)
    }
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

for (source, tool) in [("claude.svg", "Claude"), ("chatgpt.svg", "ChatGPT")] {
    let icon = load(source)
    for (suffix, sizes) in toolIconSizes {
        let points = sizes[tool]!
        writePNG(icon, points: points, scale: 1, monochrome: true,
                 to: output.appendingPathComponent("\(tool)\(suffix).png"))
        writePNG(icon, points: points, scale: 2, monochrome: true,
                 to: output.appendingPathComponent("\(tool)\(suffix)@2x.png"))
    }
}

let kimi = load("kimi.svg")
writePNG(kimi, points: kimiIconPoints, scale: 1, to: output.appendingPathComponent("KimiIcon.png"))
writePNG(kimi, points: kimiIconPoints, scale: 2, to: output.appendingPathComponent("KimiIcon@2x.png"))
