// 额度数字的颜色（UsageTint → 系统颜色）。规则在 App 核心（UsageReading）里，这里只选具体颜色；
// 列表（SwiftUI）和菜单栏（AppKit 绘制）用同一套。plain 不着色（nil）。
// 过期灰（ticket 26）取 App 核心的 StaleGray：按绘制时的外观（菜单栏或面板的明暗）选浅色/深色那个，
// 不透明，避免在彩色壁纸上的菜单栏里透出底色。

import AppKit
import SwiftUI

extension UsageTint {
    /// 菜单栏绘制用；不着色时为 nil
    var nsColor: NSColor? {
        switch self {
        case .plain: return nil
        case .stale: return Self.staleGray
        case .severity(.normal): return .systemGreen
        case .severity(.warning): return .systemOrange
        case .severity(.critical): return .systemRed
        }
    }

    private static let staleGray = NSColor(name: "CCPilotStaleGray") { appearance in
        let white = StaleGray.color(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).white
        return NSColor(srgbRed: white, green: white, blue: white, alpha: 1)
    }

    /// 列表用；不着色时为 nil（沿用默认文字颜色）
    var color: Color? {
        nsColor.map(Color.init(nsColor:))
    }
}
