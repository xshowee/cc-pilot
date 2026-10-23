// 把一串不可拆开的片段按宽度排成若干行（ticket 23）。
// 额度窗口行由"标题""剩余 N%""· 重置时间"几段组成；宽度不足时放不下的那段整段折到下一行，
// 不在段内截断（真机上出现过重置时间被截成"14:59…"）。界面的 WrappingHStack 按这里的结果摆放。

import Foundation

enum ChunkWrap {
    /// 一个片段放在第几行（从 0 开始）、离行首多远
    struct Placement: Equatable {
        let line: Int
        let x: Double
    }

    /// widths：各片段的宽度（按顺序）；maxWidth：一行最宽多少，nil 表示不限；spacing：同一行片段之间的间距。
    /// 放得下就跟在同一行，放不下就从下一行行首开始；比整行还宽的片段单独占一行（由界面在段内折行）。
    static func place(widths: [Double], maxWidth: Double?, spacing: Double) -> [Placement] {
        var result: [Placement] = []
        var line = 0
        var x = 0.0
        for (index, width) in widths.enumerated() {
            if index > 0 {
                let candidate = x + spacing
                // 留一点余量，避免文字宽度的小数误差让刚好放得下的片段折行
                if let maxWidth, candidate + width > maxWidth + 0.01 {
                    line += 1
                    x = 0
                } else {
                    x = candidate
                }
            }
            result.append(Placement(line: line, x: x))
            x += width
        }
        return result
    }
}
