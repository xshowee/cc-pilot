// 档案相关文件变化的通知（App 核心 ProfileWatcher 的界面一侧）。整个 App 只有一个：
// 档案列表（ProfileListModel）和当前档案（CurrentProfileModel）都订阅它，同一次变化只监听、处理一次。
// 通知在主线程上发出。

import Foundation

@MainActor
final class ProfileChangeFeed {
    private var subscribers: [() -> Void] = []
    private var watcher: ProfileWatcher?

    init(environment: CoreEnvironment = .live) {
        let watcher = ProfileWatcher(environment: environment) { [weak self] in
            Task { @MainActor in self?.notify() }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// 文件可能变了时在主线程上调用 handler（订阅者用 weak 引用自己，避免循环引用）
    func subscribe(_ handler: @escaping () -> Void) {
        subscribers.append(handler)
    }

    private func notify() {
        for handler in subscribers { handler() }
    }
}
