// 档案列表的一行：邮箱为主，档案名为副标题；再显示组织与订阅等级、登录状态、额度、是否与其他档案同一账号。

import SwiftUI

struct ProfileRow: View {
    let profile: Profile
    /// 这个档案所在账号的额度状态；还没刷新过时为 nil
    var usage: AccountUsage? = nil
    /// 界面时钟（UsageModel.now），用来判断变灰、已重置、还要等多久
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            Text(verbatim: profile.name)
                .font(.caption)
                .foregroundColor(.secondary)
            if let details = AccountText.details(for: profile) {
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            LoginStatusLabel(status: profile.login?.status)
            if let usage {
                UsageSummaryView(usage: usage, loginStatus: profile.login?.status, now: now)
            }
            if !profile.sameAccountAs.isEmpty {
                Label {
                    Text("Same account as \(AccountText.joinedNames(profile.sameAccountAs))")
                } icon: {
                    Image(systemName: "link")
                }
                .font(.caption)
                .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
