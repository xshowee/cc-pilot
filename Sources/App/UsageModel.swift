// 额度的界面状态：保存已获取的额度（App 核心 UsageBoard），响应"刷新全部"和单个账号的刷新按钮。
//
// 只有用户点击刷新时才调用 UsageRefresher 发请求；打开面板、启动 App、切换档案、重载档案列表
// 都只读 board，不发请求（与 ProfileListModel 的重载互不牵连）。请求在后台串行队列上逐个进行，
// 每完成一个账号就在主线程发布一次结果。还在频率限制等待期内的账号不请求（UsageBoard 判定）。
//
// now 是界面用的时钟：每 15 秒前进一次，只用来重算"N 分钟前"、变灰、已重置、还要等多久，
// 让菜单栏和面板随时间更新；它不触发任何请求。

import Combine
import Foundation
import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var board = UsageBoard()
    /// 正在刷新的账号
    @Published private(set) var refreshing: Set<UsageAccount> = []
    /// 界面时钟（见文件头）
    @Published private(set) var now = Date()

    private let refresher: UsageRefresher
    private let queue = DispatchQueue(label: "com.ccpilot.usage-refresh", qos: .userInitiated)
    private var clock: AnyCancellable?

    init(environment: CoreEnvironment = .live) {
        refresher = UsageRefresher(environment: environment)
        clock = Timer.publish(every: 15, tolerance: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.now = date }
    }

    var isRefreshing: Bool { !refreshing.isEmpty }

    func isRefreshing(_ profile: Profile) -> Bool {
        profile.usageAccount.map(refreshing.contains) ?? false
    }

    /// 这个档案所在账号的额度状态
    func usage(for profile: Profile) -> AccountUsage? {
        board.usage(for: profile)
    }

    /// 是否还在频率限制的等待期内（刷新按钮不可用）
    func isWaiting(_ profile: Profile) -> Bool {
        usage(for: profile)?.isWaiting(now: now) ?? false
    }

    /// "刷新全部"现在能否点：有不在等待期、也没在刷新的账号
    func canRefreshAny(_ profiles: [Profile]) -> Bool {
        !pending(UsageRefresher.accounts(in: profiles)).isEmpty
    }

    /// "刷新全部"：列表里每个账号请求一次（正在刷新、还在等待期内的账号跳过）
    func refreshAll(_ profiles: [Profile]) {
        start(UsageRefresher.accounts(in: profiles), profiles)
    }

    /// 刷新这个档案所在的账号
    func refresh(_ profile: Profile, in profiles: [Profile]) {
        guard let account = profile.usageAccount else { return }
        start([account], profiles)
    }

    private func pending(_ accounts: [UsageAccount]) -> [UsageAccount] {
        board.accountsAllowedToRefresh(accounts, now: Date()).filter { !refreshing.contains($0) }
    }

    private func start(_ accounts: [UsageAccount], _ profiles: [Profile]) {
        let pending = pending(accounts)
        guard !pending.isEmpty else { return }
        now = Date()
        refreshing.formUnion(pending)
        let refresher = refresher
        queue.async { [weak self] in
            for account in pending {
                let outcome = refresher.refresh(account, in: profiles, now: Date())
                Task { @MainActor in
                    guard let self else { return }
                    self.board.record(outcome)
                    self.refreshing.remove(account)
                    self.now = Date()
                }
            }
        }
    }
}
