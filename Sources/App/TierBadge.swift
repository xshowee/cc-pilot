// 订阅等级 / 套餐的小标签（Pro、Max 5x、Plus 等）。Claude 与 ChatGPT 两种档案行共用。

import SwiftUI

struct TierBadge: View {
    let name: String

    var body: some View {
        Text(verbatim: name)
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .fixedSize()
    }
}
