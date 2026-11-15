// Antigravity 一段的界面状态（spec "刷新""快照与看板"）：持有 App 核心的 AntigravityBoard，响应添加、卡片上的刷新、
// "刷新全部"和删除。面板只按 cards(now:) 画。
// 账号由用户手动添加（ticket 08）：面板底栏的"添加账号…"里选 Antigravity、输入邮箱（AddProfileForm），
// 添加只写看板和本机存储，不读 Antigravity；读到没添加过的邮箱不建卡片。
//
// 启动时从本机存储（AntigravityBoardStore）读一次看板；之后只在用户点某张卡片的刷新或"刷新全部"时读 Antigravity
// （AntigravityRefresher：找进程、调本地接口），不轮询，打开面板也不读。读取在 UsageModel 的刷新队列上，
// 与 Claude Code、ChatGPT、Kimi Code 的刷新逐个进行（UsageModel.runOnRefreshQueue）。
// 一次只读一次（AntigravityRefreshing）：每张卡片读到的都是 App 里当前登录的同一个账号。读取进行中再点
// 别的卡片的刷新不发起新的读取，但那张卡片也转圈，读取结束后同样按被点的卡片得到提示。
// 没有添加任何账号时，"刷新全部"不读 Antigravity；找不到进程时什么都不显示。
// 结果交给 board.record(_:clicked:)（被点的卡片，按点的顺序），要写回时存回本机。
// 短暂提示（"打开 Antigravity 后可刷新""Antigravity 里登录的是 <邮箱>"）显示 noticeDuration 秒，同 KimiModel.copyNotice。
// 删除先在面板里确认（AntigravityRemovalBanner），确认后从看板和本机存储删掉这个邮箱。
// 统计面板（ticket 05）按 board 取同一个邮箱的数据。

import Foundation

extension Notification.Name {
    static let antigravityWatchingDidChange = Notification.Name("CCPilotAntigravityWatchingDidChange")
}

/// antigravityWatchingDidChange 的 userInfo 键
let antigravityWatchingEnabledKey = "enabled"

@MainActor
final class AntigravityModel: ObservableObject {
    @Published private(set) var board: AntigravityBoard
    /// 正在进行的读取、被点的卡片
    @Published private(set) var refreshing = AntigravityRefreshing()
    /// 最近一次刷新给各卡片的短暂提示（按邮箱）
    @Published private(set) var notices: [String: AntigravityNotice.Kind] = [:]

    /// 卡片上的短暂提示显示多久（同 KimiModel）
    static let noticeDuration = KimiModel.noticeDuration

    private let refresher: AntigravityRefresher
    private let store: AntigravityBoardStore
    private let usage: UsageModel
    /// 每次给出提示加一：过期的隐藏不生效
    private var noticeGeneration = 0

    init(environment: CoreEnvironment = .live, usage: UsageModel) {
        refresher = AntigravityRefresher(environment: environment)
        store = AntigravityBoardStore(environment: environment)
        self.usage = usage
        board = store.load()
    }

    /// 添加过账号时面板才显示 Antigravity 一段；"刷新全部"也只在这时读 Antigravity
    var isVisible: Bool { !board.emails.isEmpty }

    func cards(now: Date) -> [AntigravityCard] { board.cards(now: now) }

    var isRefreshing: Bool { refreshing.isRunning }

    /// 这张卡片显示转圈：它被点过（包括读取进行中再点的），或读取由"刷新全部"发起
    func isRefreshing(_ email: String) -> Bool { refreshing.isSpinning(email) }

    /// 点了这张卡片的刷新；读取进行中时加入它，不发起新的读取
    func refresh(_ email: String) {
        if refreshing.click(email) { start() }
    }

    /// "刷新全部"里的 Antigravity：没有添加任何账号时不读
    func refreshAll() {
        guard isVisible else { return }
        if refreshing.clickRefreshAll() { start() }
    }

    /// 要添加的邮箱的问题（添加表单实时提示）
    func problem(forNewEmail email: String) -> AntigravityBoard.NewEmailProblem? {
        board.problem(forNewEmail: email)
    }

    /// 添加一个邮箱（不读 Antigravity）；有问题时什么都不做，返回 false
    @discardableResult
    func add(_ email: String) -> Bool {
        guard board.add(email) else { return false }
        save()
        notifyWatching()
        return true
    }

    private func start() {
        let refresher = refresher
        usage.runOnRefreshQueue({ refresher.refresh(now: Date()) }) { [weak self] result in
            self?.finish(result)
        }
    }

    private func finish(_ result: AntigravityRefreshResult) {
        let effect = board.record(result, clicked: refreshing.finish())
        if effect.needsSave { save() }
        if !effect.notices.isEmpty { show(effect.notices) }
    }

    /// 显示这次的提示（替换上一次的），noticeDuration 秒后一起隐藏
    private func show(_ notices: [AntigravityNotice]) {
        noticeGeneration += 1
        let generation = noticeGeneration
        self.notices = Dictionary(notices.map { ($0.card, $0.kind) }, uniquingKeysWith: { first, _ in first })
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.noticeDuration * 1_000_000_000))
            if generation == noticeGeneration { self.notices = [:] }
        }
    }

    /// 删除这个邮箱的卡片和快照（已确认）
    func remove(_ email: String) {
        board.remove(email)
        save()
        notices[email] = nil
        notifyWatching()
    }

    private func notifyWatching() {
        NotificationCenter.default.post(
            name: .antigravityWatchingDidChange,
            object: nil,
            userInfo: [antigravityWatchingEnabledKey: !board.emails.isEmpty])
    }

    private func save() {
        do {
            try store.save(board)
        } catch {
            NSLog("CC Pilot: 无法保存 Antigravity 快照：%@", String(describing: error))
        }
    }
}
