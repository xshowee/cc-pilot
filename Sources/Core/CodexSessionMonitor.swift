// 让会话记录读取器跟上 ChatGPT 会话（chatgpt-profiles ticket 08；09 的 Token 账本接在同一个监视器上）：
// 启动时全量扫描一次，之后监听 ~/.codex/sessions 与 ~/.codex/archived_sessions 的变化（FSEvents，不轮询），
// 合并短时间内的多次通知后增量读入，把每次扫描的结果交给 onScan。
//
// 只扫描 FSEvents 报告的目录（会话进行中每一两秒一次，没必要每次 stat 全部历史会话记录）；说不清哪里变了
// （根目录本身、需要重新扫描、事件丢失）时全量扫描。上次读不了的文件（.zst 正在写入）所在目录下次一并扫描。
// 两个目录启动时可以不存在，之后创建也能收到。
//
// 读取位置（CodexFileCursor）在内存里跟着扫描前进；启动时从 cursors 取初值（ticket 09：TokenUsageRecorder 给的是
// 账本里记着的位置，App 重启后接着读，不重读历史会话记录；不给时从头读）。
// 所有状态只在 queue 上访问；onScan 在 queue 上调用，界面需要自己切回主线程。

import CoreServices
import Foundation

final class CodexSessionMonitor: @unchecked Sendable {
    private let reader: CodexSessionReader
    /// (读取器用的目录, FSEvents 上报用的真实路径)
    private let roots: [(path: String, real: String)]
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let onScan: (CodexSessionScan) -> Void

    // 以下只在 queue 上访问
    private var running = false
    private var stream: FSEventStreamRef?
    private var cursors: [String: CodexFileCursor] = [:]
    /// 上次读不了的文件所在的目录
    private var retry: Set<String> = []

    private let initialCursors: () -> [String: CodexFileCursor]

    /// - queue: 监听、扫描、onScan 所在的串行队列（可以与使用者共用一个）
    /// - cursors: 启动时的读取位置，在 queue 上调用一次
    init(environment: CoreEnvironment, latency: TimeInterval = 1,
         queue: DispatchQueue = DispatchQueue(label: "com.ccpilot.codex-sessions", qos: .utility),
         cursors: @escaping () -> [String: CodexFileCursor] = { [:] },
         onScan: @escaping (CodexSessionScan) -> Void) {
        // 路径按解析过软链接的主目录算（FSEvents 按真实路径上报，例如 /var → /private/var）。
        // 只换 home，不新建 CoreEnvironment：其他注入（进程查询等）保持调用方给的
        var real = environment
        real.home = FSEventsSupport.realPath(environment.home)
        reader = CodexSessionReader(environment: real)
        roots = reader.roots.map { ($0, FSEventsSupport.realPath(URL(fileURLWithPath: $0)).path) }
        self.latency = latency
        self.queue = queue
        self.onScan = onScan
        initialCursors = cursors
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    /// 开始监听，并在后台全量扫描一次；重复调用无副作用
    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            cursors = initialCursors()
            stream = makeStream()
            if stream == nil { NSLog("CC Pilot: 无法监听 ChatGPT 会话目录") }
            sync(under: nil)
        }
    }

    /// 停止监听；返回后不会再有新的扫描
    func stop() {
        let body = { [self] in
            running = false
            if let s = stream { FSEventsSupport.destroy(s) }
            stream = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { body() } else { queue.sync(execute: body) }
    }

    /// directories 为 nil 时全量扫描
    private func sync(under directories: Set<String>?) {
        let scope = directories.map { Array($0.union(retry)).sorted() }
        let scan = reader.scan(cursors, under: scope)
        cursors = scan.cursors
        retry = Set(scan.deferred.map { ($0 as NSString).deletingLastPathComponent })
        onScan(scan)
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

    private func makeStream() -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let paths = roots.map(\.real) as CFArray
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
        let events = (0..<count).map { (String(cString: cPaths[$0]), flags[$0]) }
        monitor.sync(under: monitor.directories(for: events))
    }
}
