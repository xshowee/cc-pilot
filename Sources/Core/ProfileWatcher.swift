// 监听档案相关文件的变化（FSEvents），让 ccp 在终端里做的修改实时反映到界面上。
//
// 监听 ~/.claude-profiles（递归）和 ~/.claude.json。两者在启动时可以不存在，之后创建也能收到。
// 只在这些变化时通知：
//   ~/.claude.json                     默认档案的账号资料
//   ~/.claude-profiles 本身            整个档案根目录被创建或删除
//   ~/.claude-profiles/<条目>          档案目录增删、当前档案记录 active 的写入（含原子写入的临时文件）
//   ~/.claude-profiles/<名字>/.claude.json   某个档案登录、登出
// 档案目录里的运行时文件（history.jsonl、sessions/ 等）频繁变化，不通知。
// 实时额度目录 ~/.claude-profiles/.live-quota（见 LiveQuotaFiles）不算档案：其中的变化（状态栏转发写出的
// 实时额度文件、开关）只调用 onLiveQuotaChange，每批事件至多一次，所以短时间内的多次写入按 latency 合并。
// 事件丢失或需要重新扫描时（FSEvents 的 MustScanSubDirs 等标志），一律通知。
//
// 软链接档案：ProfileStore 和 ccp ls 都把"指向目录的软链接"当作档案，但 FSEvents 不跟随软链接，
// 目标目录里的变化按真实路径上报，不在 ~/.claude-profiles 之下。所以对每个指向档案根目录之外的
// 软链接档案，另开一个流监听它的目标目录（只看目标目录本身和其中的 .claude.json）；
// 档案根目录的条目一变化就重新扫描软链接，增删对应的流。
//
// 通知只说"可能变了"，不说变了什么：收到后重新调用 ProfileStore.listProfiles 即可。
// 回调在 `queue` 上执行（默认是一个后台串行队列），界面需要自己切回主线程。
// 所有流都在 `queue` 上创建和销毁；start / stop 可以在任意线程调用。

import CoreServices
import Foundation

final class ProfileWatcher {
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let onChange: () -> Void
    private let onLiveQuotaChange: (() -> Void)?
    private let homeConfig: String
    private let profilesRoot: String
    private let liveQuotaDir: String

    // 以下只在 queue 上访问
    private var rootStream: FSEventStreamRef?
    /// 软链接档案的目标目录（真实路径）→ 监听它的流
    private var linkStreams: [String: FSEventStreamRef] = [:]

    /// - latency: FSEvents 合并事件的时间窗口（秒），短时间内的多次变化合并成一次通知
    /// - onLiveQuotaChange: 实时额度目录里有变化时调用（可选；与 onChange 在同一个队列上）
    init(environment: CoreEnvironment, latency: TimeInterval = 0.3,
         queue: DispatchQueue = DispatchQueue(label: "com.ccpilot.profile-watcher"),
         onLiveQuotaChange: (() -> Void)? = nil,
         onChange: @escaping () -> Void) {
        self.latency = latency
        self.queue = queue
        self.onChange = onChange
        self.onLiveQuotaChange = onLiveQuotaChange
        // FSEvents 报告的是解析过软链接的真实路径（例如 /var → /private/var），比较前先解析 HOME
        let paths = ProfilePaths(environment: CoreEnvironment(home: Self.realPath(environment.home)))
        homeConfig = paths.defaultClaudeJSON.path
        profilesRoot = paths.profilesRootPath
        liveQuotaDir = profilesRoot + "/" + LiveQuotaFiles.directoryName
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    /// 开始监听；重复调用无副作用
    func start() {
        onQueue {
            guard rootStream == nil else { return }
            rootStream = makeStream([profilesRoot, homeConfig]) { [weak self] paths, flags in
                self?.handleRootEvents(paths, flags)
            }
            updateLinkStreams()
        }
    }

    /// 停止监听；返回后不会再有新的回调
    func stop() {
        onQueue {
            if let s = rootStream { Self.destroy(s) }
            rootStream = nil
            linkStreams.values.forEach(Self.destroy)
            linkStreams = [:]
        }
    }

    // MARK: - 内部

    private static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { body() } else { queue.sync(execute: body) }
    }

    private func handleRootEvents(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        guard rootStream != nil else { return }
        let rescan = flags.contains { $0 & Self.rescanFlags != 0 }
        if rescan || paths.contains(where: isUnderLiveQuota) { onLiveQuotaChange?() }
        guard rescan || paths.contains(where: isRelevantUnderRoot) else { return }
        updateLinkStreams()
        onChange()
    }

    private func isUnderLiveQuota(_ path: String) -> Bool {
        path == liveQuotaDir || path.hasPrefix(liveQuotaDir + "/")
    }

    private func isRelevantUnderRoot(_ path: String) -> Bool {
        if path == homeConfig || path == profilesRoot { return true }
        guard path.hasPrefix(profilesRoot + "/"), !isUnderLiveQuota(path) else { return false }
        let parts = path.dropFirst(profilesRoot.count + 1).split(separator: "/", omittingEmptySubsequences: true)
        return parts.count == 1 || (parts.count == 2 && parts[1] == ".claude.json")
    }

    /// 按档案根目录里现有的软链接档案，增删监听目标目录的流
    private func updateLinkStreams() {
        let targets = linkedProfileTargets()
        for (target, stream) in linkStreams where !targets.contains(target) {
            Self.destroy(stream)
            linkStreams[target] = nil
        }
        for target in targets where linkStreams[target] == nil {
            let config = target + "/.claude.json"
            linkStreams[target] = makeStream([target]) { [weak self] paths, flags in
                guard let self, self.linkStreams[target] != nil else { return }
                let rescan = flags.contains { $0 & Self.rescanFlags != 0 }
                if rescan || paths.contains(where: { $0 == target || $0 == config }) { self.onChange() }
            }
        }
    }

    /// 档案根目录里指向目录的软链接档案（名字合规、不是保留名，与 ProfileStore 相同）的目标真实路径；
    /// 目标在档案根目录之内的已被根目录的流覆盖，不算
    private func linkedProfileTargets() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: profilesRoot) else { return [] }
        var targets: Set<String> = []
        for name in entries where ProfileName.isProfileName(name) {
            let link = profilesRoot + "/" + name
            guard (try? fm.attributesOfItem(atPath: link))?[.type] as? FileAttributeType == .typeSymbolicLink,
                  let resolved = realpath(link, nil)
            else { continue }
            let target = String(cString: resolved)
            free(resolved)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue,
                  target != profilesRoot, !target.hasPrefix(profilesRoot + "/")
            else { continue }
            targets.insert(target)
        }
        return targets
    }

    private func makeStream(_ paths: [String],
                            _ handle: @escaping ([String], [FSEventStreamEventFlags]) -> Void) -> FSEventStreamRef? {
        let box = Handler(handle)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<Handler>.fromOpaque(info).release() }
            },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            // 创建失败时是否回调 release 没有文档说明；宁可泄漏这一个小对象，也不冒重复释放的风险
            return nil
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        return s
    }

    private static func destroy(_ s: FSEventStreamRef) {
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
        let pathList = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        handler.handle(pathList, Array(UnsafeBufferPointer(start: flags, count: count)))
    }

    private static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// 流的回调对象（FSEvents 的 context 持有它）
    private final class Handler {
        let handle: ([String], [FSEventStreamEventFlags]) -> Void
        init(_ handle: @escaping ([String], [FSEventStreamEventFlags]) -> Void) { self.handle = handle }
    }
}
