// 档案列表的一行：邮箱为主，档案名为副标题；再显示组织与订阅等级、是否与其他档案同一账号。

import SwiftUI

struct ProfileRow: View {
    let profile: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            Text(verbatim: profile.name)
                .font(.caption)
                .foregroundColor(.secondary)
            if let details = AccountText.details(profile.account.account) {
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundColor(.secondary)
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
