// 额度窗口下方的细进度条：长度是剩余比例，颜色与数字同色、略淡（severity / 变灰；不着色时用中性色）。
// 只是数字的图形化，读屏跳过它，数字本身仍由 UsageReadingText 读出。

import SwiftUI

struct UsageMeter: View {
    /// 剩余比例（0–1）
    let fraction: Double
    /// nil：服务端没给出严重程度，用中性色
    let color: Color?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color?.opacity(0.8) ?? Color.primary.opacity(0.45))
                    // 剩余不为 0 时至少露出一点，免得看起来像没有数据
                    .frame(width: fraction > 0 ? max(4, geometry.size.width * fraction) : 0)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
