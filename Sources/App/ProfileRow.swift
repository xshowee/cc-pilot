// 档案列表的一张卡片的内容：头像 + 邮箱为主标题；副标题是档案名（当前档案后面带"当前"标记）和订阅等级；
// 组织名（第三行）只在不是个人账号自动生成的那种时显示。登录正常（可以请求额度）时不显示登录状态，只在需要处理时显示。
// 下面是额度（展开时含详情）、获取时间、失败原因、是否与其他档案同一账号。
// 卡片右上角的按钮由 SwitchableProfileRow 叠在上面，headerTrailingInset 给它们留出位置，额度条仍占满整行。

import SwiftUI

struct ProfileRow: View {
    let profile: Profile
    /// 是否当前档案：是时档案名后面显示"当前"标记，头像用强调色
    var isCurrent = false
    /// 这个档案所在账号的额度状态；还没刷新过时为 nil
    var usage: AccountUsage? = nil
    /// 界面时钟（UsageModel.now），用来判断变灰、已重置、还要等多久
    var now = Date()
    /// 账号详情（按模型周窗口、超额付费）是否展开
    var expanded = false
    /// 标题区右侧留给按钮的宽度
    var headerTrailingInset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProfileAvatar(profile: profile, isCurrent: isCurrent)
                VStack(alignment: .leading, spacing: 2) {
                    title
                    subtitle
                    if let organization = AccountText.organization(for: profile) {
                        Text(verbatim: organization)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.trailing, headerTrailingInset)
            }
            // 登录正常是常态，不占一行；需要处理的状态才显示
            if let status = profile.login?.status, status != .canRequestUsage {
                LoginStatusLabel(status: status)
            }
            // 额度各项与同一账号提示按 App 核心定的顺序显示（ticket 19）
            if hasUsageContent {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ProfileRowPart.order(expanded: expanded), id: \.self) { part in
                        if part == .sameAccount {
                            sameAccount
                        } else if let usage {
                            UsageSummaryView(usage: usage, part: part, loginStatus: profile.login?.status, now: now)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 额度区有没有内容（没有时不留空白）
    private var hasUsageContent: Bool { usage != nil || !profile.sameAccountAs.isEmpty }

    @ViewBuilder private var sameAccount: some View {
        if !profile.sameAccountAs.isEmpty {
            Label {
                Text("Same account as \(AccountText.joinedNames(profile.sameAccountAs))")
            } icon: {
                Image(systemName: "link")
            }
            // 只是说明，不是警告：用次要文字颜色（橙色只留给额度"偏紧"，ticket 24）
            .foregroundColor(.secondary)
        }
    }

    /// 档案名、"当前"标记（跟在档案名后面，不挤邮箱，ticket 18）、订阅等级
    private var subtitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: profile.name)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isCurrent {
                currentBadge
            }
            if let tier = AccountText.tier(for: profile) {
                TierBadge(name: tier)
            }
        }
        .font(.caption)
    }

    private var currentBadge: some View {
        Label("Current", systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundColor(.accentColor)
            .fixedSize()
            .layoutPriority(1)
    }

    @ViewBuilder private var title: some View {
        switch profile.account {
        case .loggedIn(let account):
            Text(verbatim: account.email ?? profile.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        case .loggedOut:
            Text("Not signed in")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        case .unreadable(let error):
            Label {
                Text("Can’t read account info")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(StatusColor.red)
            .help(AccountText.explanation(error))
        }
    }
}

/// 订阅等级的小标签（Pro、Max 5x 等）
private struct TierBadge: View {
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
