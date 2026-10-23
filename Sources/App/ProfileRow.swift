// 档案列表的一行：邮箱为主，档案名为副标题（当前档案在档案名后面带"当前"标记）；
// 再显示组织与订阅等级、登录状态、额度（展开时含详情）、是否与其他档案同一账号。

import SwiftUI

struct ProfileRow: View {
    let profile: Profile
    /// 是否当前档案：是时档案名后面显示"当前"标记
    var isCurrent = false
    /// 这个档案所在账号的额度状态；还没刷新过时为 nil
    var usage: AccountUsage? = nil
    /// 界面时钟（UsageModel.now），用来判断变灰、已重置、还要等多久
    var now = Date()
    /// 账号详情（按模型周窗口、超额付费）是否展开
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: profile.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if isCurrent {
                    currentBadge
                }
            }
            if let details = AccountText.details(for: profile) {
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            LoginStatusLabel(status: profile.login?.status)
            // 额度各项与同一账号提示按 App 核心定的顺序显示（ticket 19）
            VStack(alignment: .leading, spacing: 1) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

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

    /// "当前"标记：跟在档案名后面（这一行很短），不占其他行的宽度，也不挤邮箱（ticket 18）
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
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        case .loggedOut:
            Text("Not signed in")
                .font(.body)
                .foregroundColor(.secondary)
        case .unreadable(let error):
            Label {
                Text("Can’t read account info")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.body)
            .foregroundColor(.red)
            .help(AccountText.explanation(error))
        }
    }
}
