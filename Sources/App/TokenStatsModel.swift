// 统计面板（token-usage ticket 07）的 Token 用量：从账本（TokenUsageRecorder）读出正在显示的账号的数据，
// 以及清空累计（单个账号、全部账号）。
//
// 线程：recorder 的 accountUsage / clearCumulative / clearAllCumulative 会同步等账本队列，不能在主线程上调用，
// 这里一律放到自己的后台串行队列上，结果回主线程发布。recorder 的 onUpdate 在账本队列上触发，
// AppDelegate 只用 DispatchQueue.main.async 转成 tokenUsageDidUpdate 通知（不能 main.sync：主线程可能正同步等账本队列）。
//
// 什么时候读：开始显示某个账号、它已知的 resets_at 变了（实时额度或刷新）、账本有更新（会话进行中每隔一两秒一次）、
// 清空之后（同样经 onUpdate）、界面时钟走了一格（滚动窗口随时间移动）。只读正在显示的那个账号；
// 同一时刻只有一次读取在进行，期间又要读就在完成后再读一次（合并成一次）。
// 读过的账号留着结果：在同一账号的几个档案行之间移动、或移回刚看过的账号时先显示它，读完再换成新的。
//
// "清空全部账号"从设置菜单进入，确认条显示在主面板里（confirmingClearAll），不弹系统对话框。

import Foundation

extension Notification.Name {
    /// 账本有更新（在主线程上发出）
    static let tokenUsageDidUpdate = Notification.Name("CCPilotTokenUsageDidUpdate")
}

@MainActor
final class TokenStatsModel: ObservableObject {
    /// 读过的各账号 Token 用量
    @Published private(set) var loaded: [UsageAccount: AccountTokenUsage] = [:]
    /// 主面板里是否显示"清空全部账号"的确认条
    @Published var confirmingClearAll = false

    private let recorder: TokenUsageRecorder
    private let queue = DispatchQueue(label: "com.ccpilot.token-stats", qos: .userInitiated)
    /// 正在显示的账号和它已知的 resets_at；没有显示时为 nil
    private var shown: (account: UsageAccount, resets: KnownResets)?
    private var reading = false
    private var readAgain = false
    private var observer: NSObjectProtocol?

    init(recorder: TokenUsageRecorder) {
        self.recorder = recorder
        observer = NotificationCenter.default.addObserver(forName: .tokenUsageDidUpdate, object: nil,
                                                          queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// 开始（或继续）显示这个账号
    func show(_ account: UsageAccount, resets: KnownResets) {
        if let shown, shown.account == account, shown.resets == resets { return }
        shown = (account, resets)
        reload()
    }

    /// 面板收起：不再读
    func hide() {
        shown = nil
    }

    /// 重读正在显示的账号
    func reload() {
        guard let shown else { return }
        if reading { readAgain = true; return }
        reading = true
        let recorder = recorder
        queue.async { [weak self] in
            let result = Result { try recorder.accountUsage(shown.account.id, resets: shown.resets) }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let usage): self.loaded[shown.account] = usage
                case .failure(let error): NSLog("CC Pilot: 无法读取 Token 用量：%@", String(describing: error))
                }
                self.reading = false
                if self.readAgain {
                    self.readAgain = false
                    self.reload()
                }
            }
        }
    }

    /// 清空一个账号的累计 Token 用量；完成后经 onUpdate 重读
    func clear(_ account: UsageAccount) {
        let recorder = recorder
        queue.async {
            do {
                try recorder.clearCumulative(account: account.id)
            } catch {
                NSLog("CC Pilot: 无法清空累计 Token 用量：%@", String(describing: error))
            }
        }
    }

    /// 清空全部账号的累计 Token 用量（确认条上点了"清空"）
    func clearAll() {
        confirmingClearAll = false
        let recorder = recorder
        queue.async {
            do {
                try recorder.clearAllCumulative()
            } catch {
                NSLog("CC Pilot: 无法清空全部账号的累计 Token 用量：%@", String(describing: error))
            }
        }
    }
}
