// 档案相关文件变化的通知（App 核心 ProfileWatcher 的界面一侧）。每个工具一个：
// Claude Code 的档案列表（ProfileListModel）和当前档案（CurrentProfileModel）都订阅同一个，同一次变化只监听、处理一次；
// ChatGPT 的档案列表（ChatGPTProfileListModel）订阅另一个（watching: .chatgptAuth）。
// 实时额度文件的变化（ProfileWatcher.onLiveQuotaChange）另走 subscribeLiveQuota，额度界面状态（UsageModel）订阅。
// 通知在主线程上发出。

import Foundation

@MainActor
final class ProfileChangeFeed {
    private var subscribers: [() -> Void] = []
    private var liveQuotaSubscribers: [() -> Void] = []
    private var watcher: ProfileWatcher?

    /// watching：监听哪个工具的档案。Claude Code 一侧用默认值；ChatGPT 一侧另建一个 `.chatgptAuth` 的实例，
    /// 两个工具的文件变化互不触发对方的重读。
    init(environment: CoreEnvironment = .live, watching: ProfileWatcher.Watched = .accountConfigs) {
        let watcher = ProfileWatcher(environment: environment, watching: watching, onLiveQuotaChange: { [weak self] in
            Task { @MainActor in self?.notifyLiveQuota() }
        }) { [weak self] in
            Task { @MainActor in self?.notify() }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// 文件可能变了时在主线程上调用 handler（订阅者用 weak 引用自己，避免循环引用）
    func subscribe(_ handler: @escaping () -> Void) {
        subscribers.append(handler)
    }

    /// 实时额度文件可能变了时在主线程上调用 handler（同上，用 weak 引用自己）
    func subscribeLiveQuota(_ handler: @escaping () -> Void) {
        liveQuotaSubscribers.append(handler)
    }

    private func notify() {
        for handler in subscribers { handler() }
    }

    private func notifyLiveQuota() {
        for handler in liveQuotaSubscribers { handler() }
    }
}
