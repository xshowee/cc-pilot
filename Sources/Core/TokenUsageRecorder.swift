// 让 Token 用量账本跟上会话记录：启动时回填现有的全部会话记录，之后监听 ~/.claude/projects 的变化
// （FSEvents，不轮询），合并短时间内的多次通知后增量读入。
//
// 每次同步依次：读入新追加的会话记录 → 归属钩子（默认是 SessionAttribution，按各档案的 history.jsonl
// 给待归属的明细定归属）→ 把超过保留期的已归属明细合并成按天汇总。同步完成后调用 onUpdate。
// 除了 projects/ 的变化，各档案的 history.jsonl 变化（ProfileWatcher 的 history.jsonl 模式）也触发一次同步：
// 消息可能先于 history.jsonl 的条目写出来，条目出现时要再归属一次。
// 汇总按整天进行，只在启动后第一次同步和本地日期变了之后做（算保留期要读每个档案的设置，
// 会话进行中每隔一两秒就同步一次，没必要每次都做）。
// 不按 FSEvents 报告的路径过滤：任何事件（含需要重新扫描的标志）都做一次完整的增量同步，
// 增量读取本身只读有变化的部分。projects/ 启动时可以不存在，之后创建也能收到。
//
// 账本只在 `queue`（默认是一个后台串行队列）上访问：同步、归属钩子、onUpdate 和 `read` 的 body
// 都在它上面执行，界面需要自己切回主线程。start / stop / read 可以在任意线程调用。
// 账本打不开、读入出错时跳过这一次，下次变化再试。
// 统计面板（ticket 07）用 accountUsage 查询、clearCumulative / clearAllCumulative 清空，同样在 `queue` 上执行。

import CoreServices
import Foundation

final class TokenUsageRecorder {
    private let environment: CoreEnvironment
    private let ledgerURL: URL
    private let projectsRoot: URL
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let calendar: Calendar
    private let now: () -> Date
    private let attribute: (TokenLedger) throws -> Void
    private let onUpdate: () -> Void
    private var historyWatcher: ProfileWatcher?

    // 以下只在 queue 上访问
    private var ledger: TokenLedger?
    private var stream: FSEventStreamRef?
    /// 上次汇总时的本地日期
    private var rolledUpDay: DateComponents?

    /// - ledgerURL: 账本文件，默认是 TokenLedger.defaultURL
    /// - latency: FSEvents 合并事件的时间窗口（秒）
    /// - calendar: 按天汇总用的日历和时区
    /// - attribute: 归属钩子，每次读入之后、汇总之前调用；nil（默认）是按 history.jsonl 归属的 SessionAttribution
    init(environment: CoreEnvironment, ledgerURL: URL? = nil, latency: TimeInterval = 2,
         queue: DispatchQueue = DispatchQueue(label: "com.ccpilot.token-usage", qos: .utility),
         calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init,
         attribute: ((TokenLedger) throws -> Void)? = nil,
         onUpdate: @escaping () -> Void = {}) {
        self.environment = environment
        self.ledgerURL = ledgerURL ?? TokenLedger.defaultURL(environment: environment)
        // FSEvents 按解析过软链接的真实路径工作（例如 /var → /private/var）
        projectsRoot = URL(fileURLWithPath: Self.realPath(ProfilePaths(environment: environment).homePath)
                           + "/.claude/projects")
        self.latency = latency
        self.queue = queue
        self.calendar = calendar
        self.now = now
        self.attribute = attribute ?? SessionAttribution(environment: environment, now: now).attribute
        self.onUpdate = onUpdate
        queue.setSpecific(key: queueKey, value: true)
        historyWatcher = ProfileWatcher(environment: environment, latency: latency, watching: .history) {
            [weak self] in self?.syncIfRunning()
        }
    }

    deinit { stop() }

    /// 开始监听，并在后台回填一次；重复调用无副作用
    func start() {
        queue.async { [self] in
            guard stream == nil else { return }
            stream = makeStream()
            historyWatcher?.start()
            sync()
        }
    }

    /// 停止监听；返回后不会再有新的同步。账本仍可通过 `read` 读取
    func stop() {
        onQueue {
            historyWatcher?.stop()
            if let s = stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
            }
            stream = nil
        }
    }

    /// 在后台安排一次同步（例如 history.jsonl 变了、归属可能有新进展时）
    func scheduleSync() {
        queue.async { [self] in sync() }
    }

    /// 在账本所在的队列上读取账本（等之前安排的同步做完）
    func read<T>(_ body: (TokenLedger) throws -> T) throws -> T {
        var result: Result<T, Error>!
        onQueue { result = Result { try body(try openLedger()) } }
        return try result.get()
    }

    // MARK: - Token 用量（ticket 03）

    /// 一个账号（UsageAccount.id）此刻的 Token 用量；时钟和日历用 recorder 自己的
    func accountUsage(_ account: String, resets: KnownResets) throws -> AccountTokenUsage {
        try read { try $0.accountUsage(account, resets: resets, now: now(), calendar: calendar) }
    }

    /// 清空一个账号的累计 Token 用量（起算点移到此刻），之后调用 onUpdate
    func clearCumulative(account: String) throws {
        try read { try $0.clearCumulative(account: account, at: now()) }
        onQueue(onUpdate)
    }

    /// 清空全部账号（连同未归属）的累计 Token 用量，之后调用 onUpdate
    func clearAllCumulative() throws {
        try read { try $0.clearAllCumulative(at: now()) }
        onQueue(onUpdate)
    }

    // MARK: - 内部

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { body() } else { queue.sync(execute: body) }
    }

    private func openLedger() throws -> TokenLedger {
        if let ledger { return ledger }
        let opened = try TokenLedger(at: ledgerURL)
        ledger = opened
        return opened
    }

    /// history.jsonl 变化时用：和 projects/ 的流一样，stop 之后不再同步（回调可能恰好在 stop 时排进队列）
    private func syncIfRunning() {
        queue.async { [self] in
            guard stream != nil else { return }
            sync()
        }
    }

    private func sync() {
        guard let ledger = try? openLedger() else { return }
        _ = try? ledger.ingest(projectsRoot: projectsRoot)
        try? attribute(ledger)
        let current = now()
        let day = calendar.dateComponents([.year, .month, .day], from: current)
        if day != rolledUpDay,
           (try? ledger.rollUp(now: current, retentionDays: TokenUsageRetention.days(environment: environment),
                               calendar: calendar)) != nil {
            rolledUpDay = day
        }
        onUpdate()
    }

    private func makeStream() -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        // 不要 NoDefer：第一个事件之后等满 latency 再回调，短时间内的多次变化合并成一次
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, [projectsRoot.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else { return nil }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        return s
    }

    /// 流只在 queue 上回调，stop 在 queue 上销毁流，所以回调时 self 一定还在（deinit 会先 stop）
    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let recorder = Unmanaged<TokenUsageRecorder>.fromOpaque(info).takeUnretainedValue()
        guard recorder.stream != nil else { return }
        recorder.sync()
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
