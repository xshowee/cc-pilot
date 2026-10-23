// 监听档案相关文件的变化（FSEvents），让 ccp 在终端里做的修改实时反映到界面上。
//
// 监听 ~/.claude-profiles（递归）和 ~/.claude.json。两者在启动时可以不存在，之后创建也能收到。
// 只在这些变化时通知：
//   ~/.claude.json                     默认档案的账号资料
//   ~/.claude-profiles 本身            整个档案根目录被创建或删除
//   ~/.claude-profiles/<条目>          档案目录增删、当前档案记录 active 的写入（含原子写入的临时文件）
//   ~/.claude-profiles/<名字>/.claude.json   某个档案登录、登出
// 档案目录里的运行时文件（history.jsonl、sessions/ 等）频繁变化，不通知。
// 事件丢失或需要重新扫描时（FSEvents 的 MustScanSubDirs 等标志），一律通知。
//
// 通知只说"可能变了"，不说变了什么：收到后重新调用 ProfileStore.listProfiles 即可。
// 回调在 `queue` 上执行（默认是一个后台串行队列），界面需要自己切回主线程。

import CoreServices
import Foundation

final class ProfileWatcher {
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let handler: Handler
    private var stream: FSEventStreamRef?

    /// - latency: FSEvents 合并事件的时间窗口（秒），短时间内的多次变化合并成一次通知
    init(environment: CoreEnvironment, latency: TimeInterval = 0.3,
         queue: DispatchQueue = DispatchQueue(label: "com.ccpilot.profile-watcher"),
         onChange: @escaping () -> Void) {
        self.latency = latency
        self.queue = queue
        // FSEvents 报告的是解析过软链接的真实路径（例如 /var → /private/var），比较前先解析 HOME
        let paths = ProfilePaths(environment: CoreEnvironment(home: Self.realPath(environment.home)))
        handler = Handler(homeConfig: paths.defaultClaudeJSON.path,
                          profilesRoot: paths.profilesRootPath, onChange: onChange)
    }

    deinit { stop() }

    /// 开始监听；重复调用无副作用
    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(handler).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<Handler>.fromOpaque(info).release() }
            },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context,
            [handler.profilesRoot, handler.homeConfig] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            // 创建失败时是否回调 release 没有文档说明；宁可泄漏这一个小对象，也不冒重复释放的风险
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// 停止监听；返回后不会再有新的回调
    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    // MARK: - 内部

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
        let pathList = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let flagList = UnsafeBufferPointer(start: flags, count: count)
        handler.handle(paths: pathList, flags: Array(flagList))
    }

    private static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private final class Handler {
        let homeConfig: String
        let profilesRoot: String
        let onChange: () -> Void

        init(homeConfig: String, profilesRoot: String, onChange: @escaping () -> Void) {
            self.homeConfig = homeConfig
            self.profilesRoot = profilesRoot
            self.onChange = onChange
        }

        func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
            let rescan = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            let relevant = zip(paths, flags).contains { path, flag in
                flag & rescan != 0 || isRelevant(path)
            }
            if relevant { onChange() }
        }

        private func isRelevant(_ path: String) -> Bool {
            if path == homeConfig || path == profilesRoot { return true }
            guard path.hasPrefix(profilesRoot + "/") else { return false }
            let parts = path.dropFirst(profilesRoot.count + 1).split(separator: "/", omittingEmptySubsequences: true)
            return parts.count == 1 || (parts.count == 2 && parts[1] == ".claude.json")
        }
    }
}
