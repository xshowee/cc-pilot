// ChatGPT 档案行里的登录状态：状态名 + 怎么办的提示（与 Claude 一侧的 LoginStatusLabel 同样的样式）。

import SwiftUI

struct ChatGPTLoginStatusLabel: View {
    let status: ChatGPTLoginStatus

    var body: some View {
        let title = ChatGPTLoginStatusText.title(status)
        let hint = ChatGPTLoginStatusText.hint(status)
        if title != nil || hint != nil {
            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    Label {
                        Text(verbatim: title)
                    } icon: {
                        Image(systemName: icon)
                    }
                    .foregroundColor(color)
                }
                if let hint {
                    Text(verbatim: hint)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
        }
    }

    private var icon: String {
        switch status {
        case .needsRenewal: return "arrow.clockwise.circle"
        case .incompatible: return "exclamationmark.triangle"
        case .notLoggedIn, .canRequestUsage, .apiKey: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch status {
        case .needsRenewal: return StatusColor.orange
        case .incompatible: return StatusColor.red
        case .notLoggedIn, .canRequestUsage, .apiKey: return .secondary
        }
    }
}
