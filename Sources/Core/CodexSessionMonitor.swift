// 让会话记录读取器跟上 ChatGPT 会话（chatgpt-profiles ticket 08；09 的 Token 账本接在同一个监视器上）：
// 启动时全量扫描一次，之后监听 ~/.codex/sessions 与 ~/.codex/archived_sessions 的变化，
// 合并短时间内的多次通知后增量读入，把每次扫描的结果交给 onScan。不轮询。
//
// 两种通知：
// - FSEvents：会话目录（新建、关闭、改名、.zst 归档）与写入锁目录 ~/.codex/thread-writer-locks（真实路径；
//   各档案里的 thread-writer-locks 是指向它的软链接）。
// - kqueue（DispatchSource 文件监听，.write/.extend）：正在写入的 .jsonl。macOS 上 FSEvents 只在文件创建和关闭时
//   上报，往一直开着的文件追加不报；codex 由守护进程写会话记录，整个会话期间文件一直开着，只靠 FSEvents
//   就只能读到会话刚开始的那一下。kqueue 每次追加都有事件，同样合并 latency 内的通知后只扫描所在目录。
// "正在写入"的认定：
// - 主信号：写入锁 thread-writer-locks/<会话 ID>.lock（推断获取时创建、释放时删除）。锁目录有变化时重新列一遍：
//   新出现的锁，按会话 ID 找到对应的 rollout-…-<ID>.jsonl 挂上监听并扫描所在目录（文件还没有时，之后哪次扫描
//   见到它再挂）；消失的锁摘掉监听、再扫描一次。启动时已有的锁一样挂上。
// - 兜底（锁目录不存在、或锁的生命周期与推断不符）：一次扫描里读到新内容、且最近 idleTimeout 内修改过的 .jsonl
//   也挂上；idleTimeout 内没有变化就摘掉（每次扫描时检查）。修改时间的条件让首次启动全量读历史时不给旧文件挂。
// 文件被删除、改名时摘掉。挂上的文件最多 watchLimit 个（每个占一个 fd）：满了先挤掉最久没变化的兜底监听，
// 全是锁对应的就不再挂。只监听 .jsonl：.zst 写完就关闭，FSEvents 看得到。
//
// 只扫描通知报告的目录（会话进行中每一两秒一次，没必要每次 stat 全部历史会话记录）；说不清哪里变了
// （根目录本身、需要重新扫描、事件丢失）时全量扫描。上次读不了的文件（.zst 正在写入）所在目录下次一并扫描。
// 会话目录与锁目录启动时可以不存在，之后创建也能收到。
//
// 读取位置（CodexFileCursor）：给了 cursors 时每次扫描前都从它取，位置由调用方保存（ticket 09：TokenUsageRecorder
// 给的是账本里记着的位置——App 重启后接着读，不重读历史会话记录；记入账本失败时位置不前进，下次扫描重读这一批）。
// cursors 返回 nil（账本打不开）或没给时，位置在内存里跟着扫描前进，启动时从头读。
// 调用方没处理成这一批（记入账本失败）时在 onScan 里调用 requestFullScan()：内存里的位置不前进，下一次扫描
// （不管哪个目录有变化）全量扫描——这一批所在的目录之后可能再也没有变化（会话已经结束），只等它的事件会漏掉。
// 所有状态只在 queue 上访问；onScan 在 queue 上调用，界面需要自己切回主线程。

import CoreServices
import Foundation

final class CodexSessionMonitor: @unchecked Sendable {
    private let reader: CodexSessionReader
    /// (读取器用的目录, FSEvents 上报用的真实路径)
    private let roots: [(path: String, real: String)]
    /// 写入锁目录（真实路径）
    private let lockDirectory: String
    private let latency: TimeInterval
    private let idleTimeout: TimeInterval
    private let watchLimit: Int
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let onScan: (CodexSessionScan) -> Void

    /// 一份挂着 kqueue 监听的会话记录
    private struct Watch {
        let source: DispatchSourceFileSystemObject
        /// 因为写入锁挂上的（不按 idleTimeout 摘）
        var locked: Bool
        var lastChange: Date
    }

    // 以下只在 queue 上访问
    private var running = false
    private var stream: FSEventStreamRef?
    private var cursors: [String: CodexFileCursor] = [:]
    /// 上次读不了的文件所在的目录
    private var retry: Set<String> = []
    /// 下一次扫描全量扫描（requestFullScan）
    private var needsFullScan = false
    /// 正被持有的写入锁（会话 ID，小写）
    private var heldLocks: Set<String> = []
    /// 挂着监听的会话记录（按读取器用的路径）
    private var watches: [String: Watch] = [:]
    /// kqueue 报告了、还没扫描的目录；pendingArmed 时已安排在 latency 后扫描
    private var pending: Set<String> = []
    private var pendingArmed = false

    private let cursorSource: (() -> [String: CodexFileCursor]?)?

    /// - queue: 监听、扫描、onScan 所在的串行队列（可以与使用者共用一个）
    /// - idleTimeout、watchLimit: 兜底监听多久没变化摘掉、最多同时监听几份会话记录（见文件头）
    /// - cursors: 每次扫描前在 queue 上调用，取这次的起始读取位置（见文件头）
    init(environment: CoreEnvironment, latency: TimeInterval = 1,
         queue: DispatchQueue = DispatchQueue(label: "com.ccpilot.codex-sessions", qos: .utility),
         idleTimeout: TimeInterval = 30 * 60, watchLimit: Int = 32,
         cursors: (() -> [String: CodexFileCursor]?)? = nil,
         onScan: @escaping (CodexSessionScan) -> Void) {
        // 路径按解析过软链接的主目录算（FSEvents 按真实路径上报，例如 /var → /private/var）。
        // 只换 home，不新建 CoreEnvironment：其他注入（进程查询等）保持调用方给的
        var real = environment
        real.home = FSEventsSupport.realPath(environment.home)
        reader = CodexSessionReader(environment: real)
        roots = reader.roots.map { ($0, FSEventsSupport.realPath(URL(fileURLWithPath: $0)).path) }
        lockDirectory = FSEventsSupport.realPath(URL(fileURLWithPath:
            ChatGPTProfilePaths(environment: real).defaultDirectoryPath + "/thread-writer-locks")).path
        self.latency = latency
        self.idleTimeout = idleTimeout
        self.watchLimit = watchLimit
        self.queue = queue
        self.onScan = onScan
        cursorSource = cursors
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    /// 开始监听，并在后台全量扫描一次；重复调用无副作用
    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            stream = makeStream()
            if stream == nil { NSLog("CC Pilot: 无法监听 ChatGPT 会话目录") }
            // 已有的锁在这次全量扫描之后挂上（扫描之后才认识它们的文件）
            heldLocks = listLocks()
            sync(under: nil)
        }
    }

    /// 停止监听；返回后不会再有新的扫描
    func stop() {
        let body = { [self] in
            running = false
            if let s = stream { FSEventsSupport.destroy(s) }
            stream = nil
            for watch in watches.values { watch.source.cancel() }
            watches = [:]
            heldLocks = []
            pending = []
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { body() } else { queue.sync(execute: body) }
    }

    /// 这一批没处理成：内存里的读取位置不前进，下一次扫描全量扫描（见文件头）。只能在 queue 上调用（onScan 里）
    func requestFullScan() {
        needsFullScan = true
    }

    /// directories 为 nil 时全量扫描
    private func sync(under directories: Set<String>?) {
        // kqueue 报告了、还没扫描的目录这次一并扫描
        let directories = directories.map { $0.union(pending) }
        pending = []
        let scope = needsFullScan ? nil : directories.map { Array($0.union(retry)).sorted() }
        needsFullScan = false
        let before = cursorSource?() ?? cursors
        let scan = reader.scan(before, under: scope)
        onScan(scan)
        updateWatches(after: scan, before: before)
        guard !needsFullScan else { return }
        cursors = scan.cursors
        retry = Set(scan.deferred.map { ($0 as NSString).deletingLastPathComponent })
    }

    /// 一批事件涉及的目录（读取器用的路径）；要全量扫描时为 nil
    func directories(for events: [(path: String, flags: FSEventStreamEventFlags)]) -> Set<String>? {
        var directories: Set<String> = []
        for event in events {
            var path = event.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard event.flags & FSEventsSupport.rescanFlags == 0,
                  let root = roots.first(where: { path.hasPrefix($0.real + "/") }) else { return nil }
            directories.insert(root.path + path.dropFirst(root.real.count))
        }
        return directories
    }

    // MARK: 写入锁与 kqueue 监听

    private func isLockEvent(_ path: String) -> Bool {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path == lockDirectory || path.hasPrefix(lockDirectory + "/")
    }

    /// 锁目录里现有的锁（会话 ID，小写）；目录不存在时为空
    private func listLocks() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: lockDirectory)) ?? []
        return Set(names.compactMap {
            ChatGPTSessionWriters.sessionID(inOpenFile: lockDirectory + "/" + $0)?.lowercased()
        })
    }

    /// 锁目录有变化：新出现的锁挂上监听，消失的锁摘掉，扫描涉及的目录（还不认识文件的锁等之后的扫描再挂）
    private func locksChanged() {
        let now = listLocks()
        let appeared = now.subtracting(heldLocks), gone = heldLocks.subtracting(now)
        heldLocks = now
        var directories: Set<String> = []
        for (path, watch) in watches where watch.locked {
            guard let id = Self.sessionID(of: path), gone.contains(id) else { continue }
            unwatch(path)
            directories.insert((path as NSString).deletingLastPathComponent)
        }
        for path in cursors.keys {
            guard let id = Self.sessionID(of: path), appeared.contains(id) else { continue }
            // 先挂上再扫描：两者之间的追加不会等到下一次事件才读
            watch(path, locked: true)
            directories.insert((path as NSString).deletingLastPathComponent)
        }
        if !directories.isEmpty { sync(under: directories) }
    }

    /// 一次扫描之后：锁对应的文件挂上；读到新内容、最近修改过的 .jsonl 挂上（兜底）；闲置太久的兜底监听摘掉
    private func updateWatches(after scan: CodexSessionScan, before: [String: CodexFileCursor]) {
        guard running else { return }
        let now = Date()
        for (path, watch) in watches where !watch.locked && now.timeIntervalSince(watch.lastChange) > idleTimeout {
            unwatch(path)
        }
        for (path, cursor) in scan.cursors where path.hasSuffix(".jsonl") && watches[path] == nil {
            if let id = Self.sessionID(of: path), heldLocks.contains(id) {
                watch(path, locked: true)
            } else if cursor != before[path], let modified = Self.modified(path),
                      now.timeIntervalSince(modified) <= idleTimeout {
                watch(path, locked: false, lastChange: modified)
            }
        }
    }

    /// 给会话记录挂上 kqueue 监听（已挂着时只补上 locked）。满了先挤掉最久没变化的兜底监听，挤不掉就不挂
    private func watch(_ path: String, locked: Bool, lastChange: Date? = nil) {
        guard path.hasSuffix(".jsonl") else { return }
        if let existing = watches[path] {
            watches[path]?.locked = existing.locked || locked
            return
        }
        let lastChange = lastChange ?? Self.modified(path) ?? Date()
        if watches.count >= watchLimit {
            guard let victim = watches.filter({ !$0.value.locked })
                      .min(by: { $0.value.lastChange < $1.value.lastChange }),
                  locked || victim.value.lastChange < lastChange else {
                NSLog("CC Pilot: 监听的会话记录已达上限（%d 份），%@ 不再监听", watchLimit, path)
                return
            }
            unwatch(victim.key)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
        // 弱引用：监听由 self 持有，强引用会让 deinit（以及其中的 stop）永远不发生
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.running else { return }
            self.fileChanged(path, source.data)
        }
        source.setCancelHandler { close(fd) }
        watches[path] = Watch(source: source, locked: locked, lastChange: lastChange)
        source.resume()
    }

    private func unwatch(_ path: String) {
        watches.removeValue(forKey: path)?.source.cancel()
    }

    /// kqueue 报告了一份会话记录（被删、改名时摘掉）：合并 latency 内的通知，之后扫描它所在的目录
    private func fileChanged(_ path: String, _ events: DispatchSource.FileSystemEvent) {
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            unwatch(path)
        } else {
            watches[path]?.lastChange = Date()
        }
        pending.insert((path as NSString).deletingLastPathComponent)
        guard !pendingArmed else { return }
        pendingArmed = true
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in
            guard let self else { return }
            self.pendingArmed = false
            // 期间 FSEvents 的扫描已经一并扫过时 pending 为空
            guard self.running, !self.pending.isEmpty else { return }
            self.sync(under: [])
        }
    }

    /// 会话记录文件名里的会话 ID（小写）
    private static func sessionID(of path: String) -> String? {
        CodexSessionLogParser.sessionID(fromFileName: (path as NSString).lastPathComponent)?.lowercased()
    }

    private static func modified(_ path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1e9)
    }

    // MARK: FSEvents

    private func makeStream() -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let paths = (roots.map(\.real) + [lockDirectory]) as CFArray
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else { return nil }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        return s
    }

    /// 流只在 queue 上回调，stop 在 queue 上销毁流，所以回调时 self 一定还在（deinit 会先 stop）
    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let monitor = Unmanaged<CodexSessionMonitor>.fromOpaque(info).takeUnretainedValue()
        guard monitor.running else { return }
        let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        let events = (0..<count).map { (path: String(cString: cPaths[$0]), flags: flags[$0]) }
        // 锁目录的变化不算会话目录的变化：重新列一遍锁，不因此全量扫描
        let sessions = events.filter { !monitor.isLockEvent($0.path) }
        if sessions.count < events.count { monitor.locksChanged() }
        guard !sessions.isEmpty else { return }
        monitor.sync(under: monitor.directories(for: sessions))
    }
}
