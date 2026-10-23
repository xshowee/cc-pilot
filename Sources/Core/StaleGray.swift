// 过期数字的灰色（ticket 26）。菜单栏与面板共用，浅色/深色外观各一个不透明的灰：
// 原来的 secondaryLabelColor 带透明度，叠在彩色壁纸上的菜单栏里会透出底色、对比度偏低。
// 取值保证与面板、菜单栏背景的对比度不低于 4.5:1，同时比正常文字色浅（深色外观下暗）一档，
// 仍能看出是"过时"。估算的背景和验证见 tests/swift/StaleGrayChecks.swift。
// 这里只放数值与对比度计算，具体的 NSColor 在 Sources/App/UsageTintColor.swift。

import Foundation

/// sRGB 空间里的一个灰（white 为 0–1）
struct SRGBGray: Equatable {
    let white: Double

    /// WCAG 2.x 的相对亮度
    var relativeLuminance: Double {
        white <= 0.04045 ? white / 12.92 : pow((white + 0.055) / 1.055, 2.4)
    }

    /// WCAG 2.x 的对比度（1–21），与参数顺序无关
    func contrast(with other: SRGBGray) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

enum StaleGray {
    /// 浅色外观：#5C5C5C
    static let light = SRGBGray(white: 0x5C / 255.0)
    /// 深色外观：#A8A8A8
    static let dark = SRGBGray(white: 0xA8 / 255.0)

    static func color(dark isDark: Bool) -> SRGBGray { isDark ? dark : light }
}
