// 档案名后面的"当前"标记（ticket 18）。Claude 与 ChatGPT 两种档案行共用。

import SwiftUI

struct CurrentBadge: View {
    var body: some View {
        Label("Current", systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundColor(.accentColor)
            .fixedSize()
            .layoutPriority(1)
    }
}
