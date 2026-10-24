// 额度数字的颜色（UsageTint → 具体颜色）。规则在 App 核心（UsageTint(remainingPercent:)、UsageReading）里，
// 这里只选具体颜色；列表（SwiftUI）和菜单栏（AppKit 绘制）是同一套色相，plain 不着色（nil）。
// 中间一档（yellow，剩余 21–50%）用琥珀色（systemOrange / StatusColor.orange）：纯黄在浅色菜单栏和面板上
// 几乎看不清，琥珀色仍读作"注意"，且与面板里其他提示的颜色一致。
// 菜单栏用系统原色（systemGreen 等）。面板里不用：系统原色在浅灰的面板上对比度只有 1.9 左右，
// 刺眼又不清楚，面板改为按明暗各取一个的柔和色（StatusColor）：浅色下压暗，深色下提亮并降低饱和度。
// 对比度（背景估算同 tests/swift/StaleGrayChecks.swift）：浅色面板 4.1–5.5、深色面板 4.8–6.0。
// 面板里其他的橙色、红色提示（登录状态、刷新失败、输入错误）也用 StatusColor，与额度颜色一致。
// 颜色都是动态色，在绘制时按外观（菜单栏或面板的明暗）取值。
// 过期灰（ticket 26）取 App 核心的 StaleGray：按绘制时的外观选浅色/深色那个，
// 不透明，避免在彩色壁纸上的菜单栏里透出底色。

import AppKit
import SwiftUI

extension UsageTint {
    /// 菜单栏绘制用；不着色时为 nil
    var nsColor: NSColor? {
        switch self {
        case .plain: return nil
        case .stale: return Self.staleGray
        case .green: return .systemGreen
        case .yellow: return .systemOrange
        case .red: return .systemRed
        }
    }

    private static let staleGray = NSColor(name: "CCPilotStaleGray") { appearance in
        let white = StaleGray.color(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).white
        return NSColor(srgbRed: white, green: white, blue: white, alpha: 1)
    }

    /// 列表用；不着色时为 nil（沿用默认文字颜色）
    var color: Color? {
        switch self {
        case .plain: return nil
        case .stale: return Color(nsColor: Self.staleGray)
        case .green: return StatusColor.green
        case .yellow: return StatusColor.orange
        case .red: return StatusColor.red
        }
    }
}

/// 面板里额度与提示用的绿、橙、红（见文件头）
enum StatusColor {
    static let green = Color(nsColor: make("CCPilotStatusGreen", light: 0x1E7A3E, dark: 0x6CC487))
    static let orange = Color(nsColor: make("CCPilotStatusOrange", light: 0xB05A00, dark: 0xE79E55))
    static let red = Color(nsColor: make("CCPilotStatusRed", light: 0xB3261E, dark: 0xEE7F76))

    private static func make(_ name: String, light: Int, dark: Int) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}
