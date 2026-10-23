// 档案行里的登录状态：状态名 + 怎么办的提示。还没读过钥匙串（login 为 nil）时不显示。

import SwiftUI

struct LoginStatusLabel: View {
    let status: LoginStatus?

    var body: some View {
        if let status, let title = LoginStatusText.title(status) {
            VStack(alignment: .leading, spacing: 1) {
                Label {
                    Text(verbatim: title)
                } icon: {
                    Image(systemName: icon(status))
                }
                .foregroundColor(color(status))
                if let hint = LoginStatusText.hint(status) {
                    Text(verbatim: hint)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
        }
    }

    private func icon(_ status: LoginStatus) -> String {
        switch status {
        case .canRequestUsage: return "checkmark.circle"
        case .needsRenewal: return "arrow.clockwise.circle"
        case .needsReLogin: return "person.crop.circle.badge.exclamationmark"
        case .usageUnsupported: return "chart.bar.xaxis"
        case .incompatible: return "exclamationmark.triangle"
        case .notLoggedIn, .accountUnreadable: return "questionmark.circle"
        }
    }

    private func color(_ status: LoginStatus) -> Color {
        switch status {
        case .canRequestUsage: return .secondary
        case .needsRenewal, .usageUnsupported: return StatusColor.orange
        case .needsReLogin, .incompatible: return StatusColor.red
        case .notLoggedIn, .accountUnreadable: return .secondary
        }
    }
}
