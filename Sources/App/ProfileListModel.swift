// 档案列表的界面状态：启动时读一次，之后由 ProfileWatcher 在文件变化时触发重读。
// 读文件在后台串行队列上做（~/.claude.json 可能有几 MB），结果回到主线程发布。

import Foundation
import SwiftUI

@MainActor
final class ProfileListModel: ObservableObject {
    @Published private(set) var profiles: [Profile] = []

    private let store: ProfileStore
    private let loadQueue = DispatchQueue(label: "com.ccpilot.profile-load", qos: .userInitiated)
    private var watcher: ProfileWatcher?

    init(environment: CoreEnvironment = .live) {
        store = ProfileStore(environment: environment)
        let watcher = ProfileWatcher(environment: environment) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher.start()
        self.watcher = watcher
        reload()
    }

    /// 重新列出档案（不阻塞主线程）。连续调用时只采用最后一次请求的结果。
    func reload() {
        generation += 1
        let request = generation
        let store = store
        loadQueue.async { [weak self] in
            let list = store.listProfiles()
            Task { @MainActor in
                guard let self, request == self.generation, list != self.profiles else { return }
                self.profiles = list
            }
        }
    }

    private var generation = 0
}
