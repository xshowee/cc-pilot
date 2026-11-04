// ChatGPT 档案行里的额度（chatgpt-profiles ticket 07）：两个主窗口（剩余百分比、重置时间、进度条）、
// 最近一次拿到数据的时间、最近一次刷新失败的原因。显示、变灰、"已重置，待刷新"、颜色都复用 Claude 一侧
// （UsageSummaryView、UsageWindowLine）；只有登录相关的失败原因换成 ChatGPT 的文字——Claude 的提示会让用户去打开
// claude。看板里的登录状态是映射过的 LoginStatus（见 ChatGPTUsageRefresher 文件头），这里映射回来。

import SwiftUI

struct ChatGPTUsageSummary: View {
    let usage: AccountUsage
    /// 档案行已显示的登录状态；失败原因是同一个状态时不重复提示
    let loginStatus: ChatGPTLoginStatus
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageSummaryView(usage: usage, part: .mainWindows, now: now)
            UsageSummaryView(usage: usage, part: .fetchedAt, now: now)
            if case .login(let status) = usage.problem {
                if let text = loginProblemText(status) {
                    Label {
                        Text(verbatim: text)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .foregroundColor(StatusColor.orange)
                }
            } else {
                UsageSummaryView(usage: usage, part: .problem, now: now)
            }
        }
        .font(.caption)
    }

    private func loginProblemText(_ status: LoginStatus) -> String? {
        let chatgpt: ChatGPTLoginStatus
        switch status {
        case .needsRenewal, .needsReLogin: chatgpt = .needsRenewal
        case .notLoggedIn: chatgpt = .notLoggedIn
        case .usageUnsupported: chatgpt = .apiKey
        case .canRequestUsage: return nil
        case .incompatible, .accountUnreadable: chatgpt = .incompatible(.malformed)
        }
        guard chatgpt != loginStatus else { return nil }
        let parts = [ChatGPTLoginStatusText.title(chatgpt), ChatGPTLoginStatusText.hint(chatgpt)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}
