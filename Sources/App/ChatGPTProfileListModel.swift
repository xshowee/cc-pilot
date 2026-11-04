// ChatGPT 档案列表与 ChatGPT 当前档案的界面状态（chatgpt-profiles ticket 02）：启动时读一次，之后由 ChatGPT 的
// ProfileChangeFeed（watching: .chatgptAuth）在 ~/.codex-profiles/ 或各档案 auth.json 变化时触发重读，
// 所以 ccp chatgpt、codex login / logout 做的改动即时出现。打开面板时也重读（access token 是否过期随时间变化）。
// 读文件在后台串行队列上做，结果回到主线程发布。只读：不写任何文件，不联网；结果不含令牌。
// 没有默认档案 ~/.codex 时 profiles 为空，面板不显示 ChatGPT 一段。

import Foundation
import SwiftUI

@MainActor
final class ChatGPTProfileListModel: ObservableObject {
    @Published private(set) var profiles: [ChatGPTProfile] = []
    /// ChatGPT 当前档案名（"default" 表示默认档案）；可能是一个已不存在的档案名
    @Published private(set) var currentName: String = ProfileName.defaultName

    private let store: ChatGPTProfileStore
    private let loadQueue = DispatchQueue(label: "com.ccpilot.chatgpt-profile-load", qos: .userInitiated)
    private let changes: ProfileChangeFeed

    init(environment: CoreEnvironment = .live, changes: ProfileChangeFeed) {
        store = ChatGPTProfileStore(environment: environment)
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
        let store = store
        loadQueue.async { [weak self] in
            let list = store.listProfiles()
            let current = store.currentProfileName()
            Task { @MainActor in
                guard let self, request == self.generation else { return }
                if list != self.profiles { self.profiles = list }
                if current != self.currentName { self.currentName = current }
            }
        }
    }

    private var generation = 0
}
