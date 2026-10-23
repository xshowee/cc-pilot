// 档案行左边的圆形头像：邮箱（未登录时用档案名）的首字母。当前档案用强调色填充，其他档案用中性色。

import SwiftUI

struct ProfileAvatar: View {
    let profile: Profile
    let isCurrent: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isCurrent ? Color.accentColor : Color.primary.opacity(0.09))
            Text(verbatim: initial)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(isCurrent ? .white : .secondary)
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private var initial: String {
        let source = profile.account.account?.email ?? profile.name
        return source.first.map { String($0).uppercased() } ?? "?"
    }
}
