// ticket 26：过期灰色调深。菜单栏与面板用同一个不透明灰（浅色/深色各一个），
// 与对应背景的对比度不低于 4.5:1（WCAG 2.x 公式），且与正常文字色仍可区分。
//
// 背景是估算值（sRGB 灰阶 0–255）：
//   面板：MenuBarExtra 窗口的材质底色，浅色约 #ECECEC，深色约 #323232
//   菜单栏：系统半透明菜单栏叠在彩色壁纸上，取偏不利的估算——浅色约 #DCDCDC，深色约 #3C3C3C
// 正常文字色取 NSColor.labelColor 的实测值：浅色为 85% 不透明的黑，深色为 85% 不透明的白。

import Foundation

final class StaleGrayChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("对比度按 WCAG 公式计算：黑白 21:1，#767676 对白约 4.54:1", contrastFormula),
            Check("过期灰与面板、菜单栏背景的对比度不低于 4.5:1（浅色与深色，ticket 26）", staleContrast),
            Check("过期灰比原来的 secondaryLabelColor 更醒目（ticket 26）", darkerThanSecondaryLabel),
            Check("过期灰与正常文字色仍可区分：介于文字色与背景之间，对比度至少 1.5:1（ticket 26）", distinctFromLabel),
        ]
    }

    static let backgrounds: [(name: String, dark: Bool, level: Double)] = [
        ("浅色面板", false, 236), ("浅色菜单栏", false, 220),
        ("深色面板", true, 50), ("深色菜单栏", true, 60),
    ]

    static func gray(_ level: Double) -> SRGBGray { SRGBGray(white: level / 255) }

    /// 带透明度的灰叠在背景上的结果
    static func over(_ white: Double, alpha: Double, on bg: Double) -> SRGBGray {
        SRGBGray(white: white * alpha + bg / 255 * (1 - alpha))
    }

    static func contrastFormula() throws {
        try expect(abs(gray(0).contrast(with: gray(255)) - 21) < 0.01, "黑白应为 21:1")
        try expect(abs(gray(255).contrast(with: gray(0)) - 21) < 0.01, "对比度与参数顺序无关")
        try expect(abs(gray(0x76).contrast(with: gray(255)) - 4.54) < 0.01, "#767676 对白应约 4.54:1")
        try expect(abs(gray(128).contrast(with: gray(128)) - 1) < 0.0001, "同色应为 1:1")
    }

    static func staleContrast() throws {
        for bg in backgrounds {
            let ratio = StaleGray.color(dark: bg.dark).contrast(with: gray(bg.level))
            try expect(ratio >= 4.5, "\(bg.name)：对比度 \(ratio) 低于 4.5")
        }
    }

    static func darkerThanSecondaryLabel() throws {
        // secondaryLabelColor 实测：浅色为 50% 的黑，深色为 55% 的白
        for bg in backgrounds {
            let old = over(bg.dark ? 1 : 0, alpha: bg.dark ? 0.55 : 0.5, on: bg.level)
            let new = StaleGray.color(dark: bg.dark).contrast(with: gray(bg.level))
            try expect(new > old.contrast(with: gray(bg.level)), "\(bg.name)：没有比原来更醒目")
        }
    }

    static func distinctFromLabel() throws {
        for bg in backgrounds {
            let label = over(bg.dark ? 1 : 0, alpha: 0.85, on: bg.level)
            let stale = StaleGray.color(dark: bg.dark)
            let background = gray(bg.level)
            let between = bg.dark
                ? label.white > stale.white && stale.white > background.white
                : label.white < stale.white && stale.white < background.white
            try expect(between, "\(bg.name)：过期灰应介于文字色与背景之间")
            let ratio = stale.contrast(with: label)
            try expect(ratio >= 1.5, "\(bg.name)：与正常文字色对比度 \(ratio) 太接近")
        }
    }
}
