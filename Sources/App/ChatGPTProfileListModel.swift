// ChatGPT 档案列表与 ChatGPT 当前档案的界面状态（chatgpt-profiles ticket 02）：启动时读一次，之后由 ChatGPT 的
// ProfileChangeFeed（watching: .chatgptAuth）在 ~/.codex-profiles/ 或各档案 auth.json 变化时触发重读，
// 所以 ccp chatgpt、codex login / logout 做的改动即时出现。打开面板时也重读（access token 是否过期随时间变化）。
// 读文件在后台串行队列上做，结果回到主线程发布。只读：不写任何文件，不联网；结果不含令牌。
// 没有默认档案 ~/.codex 时 profiles 为空，面板不显示 ChatGPT 一段。
// 同时读 launchd 里的 CODEX_HOME（ticket 06：它仍指向的档案不能删除）；launchd 环境变化没有通知，
// 切换（ccp chatgpt use 会写当前档案记录，触发重读）和打开面板时跟着更新。

import Foundation
import SwiftUI

@MainActor
final class ChatGPTProfileListModel: ObservableObject {
    @Published private(set) var profiles: [ChatGPTProfile] = []
    /// ChatGPT 当前档案名（"default" 表示默认档案）；可能是一个已不存在的档案名
    @Published private(set) var currentName: String = ProfileName.defaultName
    /// launchd 里的 CODEX_HOME；未设置或读不到时为 nil
    @Published private(set) var launchdCodexHome: String?

    private let store: ChatGPTProfileStore
    private let launchd: LaunchdEnvironment
    private let loadQueue = DispatchQueue(label: "com.ccpilot.chatgpt-profile-load", qos: .userInitiated)
    private let changes: ProfileChangeFeed

    init(environment: CoreEnvironment = .live, changes: ProfileChangeFeed) {
        store = ChatGPTProfileStore(environment: environment)
        launchd = LaunchdEnvironment(environment: environment)
        self.changes = changes
        changes.subscribe { [weak self] in self?.reload() }
        reload()
    }

    /// 是否显示 ChatGPT 一段
    var isVisible: Bool { !profiles.isEmpty }

    /// 重新列出档案、读取当前档案（不阻塞主线程）。连续调用时只采用最后一次请求的结果。
    func reload() {
        generation += 1
        let request = generation
        let store = store, launchd = launchd
        loadQueue.async { [weak self] in
            let list = store.listProfiles()
            let current = store.currentProfileName()
            // 没有 ChatGPT 一段时不用读（也就不调用 launchctl）
            let launchdHome = list.isEmpty ? nil : launchd.codexHome()
            Task { @MainActor in
                guard let self, request == self.generation else { return }
                if list != self.profiles { self.profiles = list }
                if current != self.currentName { self.currentName = current }
                if launchdHome != self.launchdCodexHome { self.launchdCodexHome = launchdHome }
            }
        }
    }

    private var generation = 0
}
