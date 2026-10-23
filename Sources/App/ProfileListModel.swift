// 档案列表的界面状态：启动时读一次，之后由 ProfileChangeFeed（与 CurrentProfileModel 共用一个
// ProfileWatcher）在文件变化时触发重读。
// 读文件在后台串行队列上做（~/.claude.json 可能有几 MB），结果回到主线程发布。
// 重读时顺带用 LoginChecker 读取钥匙串、判定登录状态（只读，不联网；结果不含凭据）：
// 打开面板时全部重新读取；文件变化引起的重读只查询账号资料变了的档案（~/.claude.json 在
// Claude Code 运行时经常被改写，不必每次都给每个档案跑一遍 security）。

import Foundation
import SwiftUI

@MainActor
final class ProfileListModel: ObservableObject {
    @Published private(set) var profiles: [Profile] = []

    private let store: ProfileStore
    private let loginChecker: LoginChecker
    private let loadQueue = DispatchQueue(label: "com.ccpilot.profile-load", qos: .userInitiated)
    private let changes: ProfileChangeFeed

    init(environment: CoreEnvironment = .live, changes: ProfileChangeFeed) {
        store = ProfileStore(environment: environment)
        loginChecker = LoginChecker(environment: environment)
        self.changes = changes
        changes.subscribe { [weak self] in self?.reload(rereadKeychain: false) }
        reload()
    }

    /// 重新列出档案（不阻塞主线程）。连续调用时只采用最后一次请求的结果。
    /// rereadKeychain 为 false 时，账号资料没变的档案沿用当前的登录状态，不查询钥匙串。
    func reload(rereadKeychain: Bool = true) {
        generation += 1
        let request = generation
        let store = store
        let loginChecker = loginChecker
        let previous = rereadKeychain ? [] : profiles
        loadQueue.async { [weak self] in
            let list = loginChecker.withLoginStates(store.listProfiles(), reusing: previous)
            Task { @MainActor in
                guard let self, request == self.generation, list != self.profiles else { return }
                self.profiles = list
            }
        }
    }

    private var generation = 0
}
