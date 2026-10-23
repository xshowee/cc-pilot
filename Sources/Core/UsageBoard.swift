// 已获取的额度，按账号保存（只在内存里，只用于显示；不含凭据）。
//
// 界面持有一个 UsageBoard：刷新得到的 UsageRefreshOutcome 交给 record(_:)，
// 档案行和菜单栏按档案查 snapshot(for:)。查询不读文件、不读钥匙串、不联网，
// 所以打开面板、启动 App、切换档案、重载档案列表都不会触发请求。

import Foundation

struct UsageBoard: Equatable {
    private var snapshots: [UsageAccount: UsageSnapshot] = [:]

    init() {}

    /// 保存一次刷新的结果。只有成功才替换；失败时保留上一次成功获取的数据（它带着自己的获取时间）。
    mutating func record(_ outcome: UsageRefreshOutcome) {
        if let snapshot = outcome.result.snapshot { snapshots[outcome.account] = snapshot }
    }

    /// 这个档案所在账号最近一次成功获取的额度；还没刷新过、或档案未登录时为 nil
    func snapshot(for profile: Profile) -> UsageSnapshot? {
        profile.usageAccount.flatMap { snapshots[$0] }
    }

    /// 菜单栏两行：当前档案名，以及它所在账号的 5 小时窗口剩余百分比。
    /// 当前档案不在列表里、未登录、还没刷新过、或 5 小时窗口没有数字时，第二行是"—"。
    func menuBarSummary(currentProfile name: String, profiles: [Profile]) -> MenuBarSummary {
        let remaining = profiles.first { $0.name == name }
            .flatMap { snapshot(for: $0) }?.fiveHour?.remainingPercent
        return MenuBarSummary(profileName: name, fiveHourRemaining: remaining)
    }
}
