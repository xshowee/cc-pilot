// 一个额度窗口的数字部分，按 App 核心算好的 UsageReading 显示（ticket 13 的按模型周窗口也用它）：
//   remaining           "剩余 N%"，颜色取自 tint（severity / 变灰；plain 不着色）
//   resetPendingRefresh "已重置，待刷新"，不显示旧数字
//   unavailable         "—"

import SwiftUI

struct UsageReadingText: View {
    let reading: UsageReading

    var body: some View {
        switch reading {
        case .remaining(let percent, let tint):
            Text("\(percent)% left")
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundColor(tint.color)
        case .resetPendingRefresh:
            Text("Reset, refresh to update")
                .foregroundColor(.secondary)
        case .unavailable:
            Text(verbatim: "—")
                .foregroundColor(.secondary)
        }
    }
}
