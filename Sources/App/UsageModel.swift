// 额度的界面状态：保存已获取的额度（App 核心 UsageBoard），响应"刷新全部"和单个账号的刷新按钮。
//
// 只有用户点击刷新时才调用 UsageRefresher 发请求；打开面板、启动 App、切换档案、重载档案列表
// 都只读 board，不发请求（与 ProfileListModel 的重载互不牵连）。请求在后台串行队列上逐个进行，
// 每完成一个账号就在主线程发布一次结果。

import Foundation
import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var board = UsageBoard()
    /// 正在刷新的账号
    @Published private(set) var refreshing: Set<UsageAccount> = []

    private let refresher: UsageRefresher
    private let queue = DispatchQueue(label: "com.ccpilot.usage-refresh", qos: .userInitiated)

    init(environment: CoreEnvironment = .live) {
        refresher = UsageRefresher(environment: environment)
    }

    var isRefreshing: Bool { !refreshing.isEmpty }

    func isRefreshing(_ profile: Profile) -> Bool {
        profile.usageAccount.map(refreshing.contains) ?? false
    }

    /// "刷新全部"：列表里每个账号请求一次（正在刷新的账号跳过）
    func refreshAll(_ profiles: [Profile]) {
        start(UsageRefresher.accounts(in: profiles), profiles)
    }

    /// 刷新这个档案所在的账号
    func refresh(_ profile: Profile, in profiles: [Profile]) {
        guard let account = profile.usageAccount else { return }
        start([account], profiles)
    }

    private func start(_ accounts: [UsageAccount], _ profiles: [Profile]) {
        let pending = accounts.filter { !refreshing.contains($0) }
        guard !pending.isEmpty else { return }
        refreshing.formUnion(pending)
        let refresher = refresher
        queue.async { [weak self] in
            for account in pending {
                let outcome = refresher.refresh(account, in: profiles, now: Date())
                Task { @MainActor in
                    guard let self else { return }
                    self.board.record(outcome)
                    self.refreshing.remove(account)
                }
            }
        }
    }
}
