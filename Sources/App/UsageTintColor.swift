// 额度数字的颜色（UsageTint → 系统颜色）。规则在 App 核心（UsageReading）里，这里只选具体颜色；
// 列表（SwiftUI）和菜单栏（AppKit 绘制）用同一套。plain 不着色（nil）。

import AppKit
import SwiftUI

extension UsageTint {
    /// 菜单栏绘制用；不着色时为 nil
    var nsColor: NSColor? {
        switch self {
        case .plain: return nil
        case .stale: return .secondaryLabelColor
        case .severity(.normal): return .systemGreen
        case .severity(.warning): return .systemOrange
        case .severity(.critical): return .systemRed
        }
    }

    /// 列表用；不着色时为 nil（沿用默认文字颜色）
    var color: Color? {
        nsColor.map(Color.init(nsColor:))
    }
}
