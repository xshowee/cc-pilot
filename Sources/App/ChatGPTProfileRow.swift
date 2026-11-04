// ChatGPT 档案卡片的内容（chatgpt-profiles ticket 02），版式与 Claude 一侧的 ProfileRow 相同：
// 头像 + 邮箱为主标题；副标题是档案名（当前档案后面带"当前"标记）和套餐。
// 下面是需要处理的登录状态（待续期、API key、版本不兼容；登录正常时不占一行）和"与……为同一账号"。
// 额度（ticket 07）在登录状态与同一账号提示之间：两个主窗口、获取时间、失败原因（ChatGPTUsageSummary）。
// 套餐优先用最近一次刷新时响应里的 plan_type。

import SwiftUI

struct ChatGPTProfileRow: View {
    let profile: ChatGPTProfile
    var isCurrent = false
    /// 这个档案所在账号的额度状态；还没刷新过时为 nil
    var usage: AccountUsage? = nil
    /// 界面时钟（UsageModel.now）
    var now = Date()
    /// 最近一次刷新时响应里的套餐（UsageModel.reportedPlan）
    var reportedPlan: String? = nil
    /// 标题区右侧留给按钮的宽度
    var headerTrailingInset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProfileAvatar(source: profile.account?.email ?? profile.name, isCurrent: isCurrent)
                VStack(alignment: .leading, spacing: 2) {
                    title
                    subtitle
                }
                .padding(.trailing, headerTrailingInset)
            }
            if profile.status != .canRequestUsage && profile.status != .notLoggedIn {
                ChatGPTLoginStatusLabel(status: profile.status)
            }
            if let usage {
                ChatGPTUsageSummary(usage: usage, loginStatus: profile.status, now: now)
            }
            if !profile.sameAccountAs.isEmpty {
                Label {
                    Text("Same account as \(AccountText.joinedNames(profile.sameAccountAs))")
                } icon: {
                    Image(systemName: "link")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: profile.name)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isCurrent {
                CurrentBadge()
            }
            if let plan = ChatGPTAccountText.plan(for: profile, reported: reportedPlan) {
                TierBadge(name: plan)
            }
        }
        .font(.caption)
    }

    @ViewBuilder private var title: some View {
        switch profile.status {
        case .canRequestUsage, .needsRenewal:
            Text(verbatim: profile.account?.email ?? profile.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        case .notLoggedIn:
            Text("Not signed in")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        case .apiKey:
            Text("Signed in with an API key")
                .font(.system(size: 13, weight: .medium))
        case .incompatible:
            Label {
                Text("Can’t read account info")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(StatusColor.red)
        }
    }
}
