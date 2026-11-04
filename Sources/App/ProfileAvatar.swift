// 档案行左边的圆形头像：邮箱（未登录时用档案名）的首字母。当前档案用强调色填充，其他档案用中性色。
// Claude 与 ChatGPT 两种档案行共用：ChatGPT 档案用 init(source:isCurrent:)。

import SwiftUI

struct ProfileAvatar: View {
    /// 取首字母的文字：邮箱，没有时用档案名
    let source: String
    let isCurrent: Bool

    init(source: String, isCurrent: Bool) {
        self.source = source
        self.isCurrent = isCurrent
    }

    init(profile: Profile, isCurrent: Bool) {
        self.init(source: profile.account.account?.email ?? profile.name, isCurrent: isCurrent)
    }

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
        source.first.map { String($0).uppercased() } ?? "?"
    }
}
