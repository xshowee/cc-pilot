// ChatGPT 档案行的统计面板（chatgpt-profiles ticket 10）：与 Claude 用同一个面板，显示档案所在 ChatGPT 账号的数据。
// 账号键与账本、额度看板相同（ChatGPTProfile.usageAccount："chatgpt:<用户>:<工作区>"），同一账号的几个档案显示同一份；
// 没有可用账号（未登录、API key、读不懂）的档案没有面板。窗口按这个账号自己的额度窗口对齐（界面用
// KnownResets(usage: board.usage(for: 档案)) 取 resets_at，规则同 Claude）。

import Foundation

extension StatsFlyoutTarget {
    init?(chatgpt profile: ChatGPTProfile) {
        guard let account = profile.usageAccount else { return nil }
        self.init(account: account, email: profile.account?.email)
    }
}
