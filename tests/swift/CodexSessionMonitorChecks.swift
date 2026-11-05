// chatgpt-profiles ticket 08：启动时全量读一次 ChatGPT 会话记录，之后监听两个会话目录的变化（FSEvents）增量读入。
// 接口：CodexSessionMonitor(environment:latency:onScan:).start()；directories(for:)（事件 → 要扫描的目录）。
// 用真实文件系统事件，每一步最多等 5 秒。会话记录是合成的。
// 写完就关闭的写法 FSEvents 看得到；一直开着只追加（codex 守护进程的写法）要靠 kqueue，见 OpenWriter 的两项。

import CoreServices
import Foundation

final class CodexSessionMonitorChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("启动时读入已有的会话记录；之后追加的事件自动读入，不重复", backfillsThenFollows),
            Check("同一批变化报告了父目录与子目录（零点新建日期目录时）也不重复读入", followsNestedDirectoriesOnce),
            Check("会话目录启动时还不存在，之后创建也能读入", picksUpRootsCreatedLater),
            Check("只扫描事件报告的目录；根目录本身变化或要求重新扫描时全量", scopesToReportedDirectories),
            Check("写入者一直开着会话记录追加写入（不关闭，FSEvents 不报）也能读入", followsAppendsToOpenFile),
            Check("写入锁出现后，锁出现前就有的会话记录在一直开着时的追加也能读入", followsLockedSessionAppends),
        ]
    }

    final class Collected {
        private let lock = NSLock()
        private var events: [CodexTokenCountEvent] = []
        func add(_ scan: CodexSessionScan) { lock.withLock { events += scan.events } }
        var all: [CodexTokenCountEvent] { lock.withLock { events } }

        func wait(for count: Int, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if all.count >= count { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return all.count >= count
        }
    }

    static let t0 = CodexSessionReaderChecks.t0
    static let id = CodexSessionReaderChecks.sessionA

    static func backfillsThenFollows() throws {
        let home = try TempHome()
        defer { home.remove() }
        let path = CodexRollout.path(id)
        try home.write(path, CodexRollout.file([
            CodexRollout.meta(id: id, at: t0),
            CodexRollout.tokenCount(at: t0, last: .init(input: 1, output: 1)),
        ]))
        let collected = Collected()
        let monitor = CodexSessionMonitor(environment: home.environment, latency: 0.05) { collected.add($0) }
        monitor.start()
        defer { monitor.stop() }
        try expect(collected.wait(for: 1), "启动后 5 秒内没有读入已有的会话记录")

        let handle = try FileHandle(forWritingTo: home.url.appendingPathComponent(path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((CodexRollout.tokenCount(at: t0, last: .init(input: 2, output: 1),
                                                                   total: .init(input: 3, output: 2)) + "\n").utf8))
        try handle.close()
        try expect(collected.wait(for: 2), "追加的事件 5 秒内没有读入")
        Thread.sleep(forTimeInterval: 0.3)
        try expectEqual(collected.all.map(\.usage?.input), [1, 2])
    }

    static func followsNestedDirectoriesOnce() throws {
        let home = try TempHome()
        defer { home.remove() }
        let path = CodexRollout.path(id)
        try home.write(path, CodexRollout.file([
            CodexRollout.meta(id: id, at: t0),
            CodexRollout.tokenCount(at: t0, last: .init(input: 1, output: 1)),
        ]))
        let collected = Collected()
        // 合并窗口放长，让新建目录与追加写入落在同一批通知里。没合并到一批时是两次各自正确的扫描，
        // 本检查不会误报、只是抓不到回归；确定性的守护是 CodexSessionReaderChecks 的"目录互相包含"
        let monitor = CodexSessionMonitor(environment: home.environment, latency: 0.5) { collected.add($0) }
        monitor.start()
        defer { monitor.stop() }
        try expect(collected.wait(for: 1), "启动后 5 秒内没有读入已有的会话记录")
        Thread.sleep(forTimeInterval: 0.6)

        // 新的一天：sessions/2026/11 下新建 05 目录（报告 2026/11），同时 04 里的会话继续写（报告 2026/11/04）
        try FileManager.default.createDirectory(
            at: home.url.appendingPathComponent(".codex/sessions/2026/11/05"), withIntermediateDirectories: true)
        let handle = try FileHandle(forWritingTo: home.url.appendingPathComponent(path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((CodexRollout.tokenCount(at: t0, last: .init(input: 2, output: 1),
                                                                   total: .init(input: 3, output: 2)) + "\n").utf8))
        try handle.close()
        try expect(collected.wait(for: 2), "追加的事件 5 秒内没有读入")
        Thread.sleep(forTimeInterval: 1)
        try expectEqual(collected.all.map(\.usage?.input), [1, 2])
    }

    static func picksUpRootsCreatedLater() throws {
        let home = try TempHome()
        defer { home.remove() }
        let collected = Collected()
        let monitor = CodexSessionMonitor(environment: home.environment, latency: 0.05) { collected.add($0) }
        monitor.start()
        defer { monitor.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        try home.write(CodexRollout.path(id, root: "archived_sessions"), CodexRollout.file([
            CodexRollout.meta(id: id, at: t0),
            CodexRollout.tokenCount(at: t0, last: .init(input: 1, output: 1)),
        ]))
        try expect(collected.wait(for: 1), "新建的会话目录里的记录 5 秒内没有读入")
    }

    static func scopesToReportedDirectories() throws {
        let home = try TempHome()
        defer { home.remove() }
        let monitor = CodexSessionMonitor(environment: home.environment) { _ in }
        let real = FSEventsSupport.realPath(home.url).path
        let none = FSEventStreamEventFlags(kFSEventStreamEventFlagNone)
        try expectEqual(monitor.directories(for: [(real + "/.codex/sessions/2026/11/04/", none),
                                                  (real + "/.codex/archived_sessions/2026/10", none)]),
                        [real + "/.codex/sessions/2026/11/04", real + "/.codex/archived_sessions/2026/10"])
        try expect(monitor.directories(for: [(real + "/.codex/sessions", none)]) == nil, "根目录本身变化时全量")
        try expect(monitor.directories(for: [(real + "/.codex/sessions/2026",
                                              FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))]) == nil,
                   "要求重新扫描时全量")
        try expect(monitor.directories(for: [(real + "/.codex/other", none)]) == nil, "说不清的路径全量")
    }

    /// 模仿 codex 守护进程：打开会话记录后整个会话期间不关闭，只追加（macOS 上 FSEvents 只报创建与关闭）
    final class OpenWriter {
        private let fd: Int32
        init(_ url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            try expect(fd >= 0, "打不开 \(url.path)")
        }
        func append(_ lines: [String]) throws {
            let data = Data(CodexRollout.file(lines).utf8)
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            try expect(written == data.count, "写入失败")
        }
        /// 只在检查结束时调用（defer），检查过程中文件一直开着
        func close() { _ = Darwin.close(fd) }
    }

    static func tokenCount(_ n: Int) -> String {
        CodexRollout.tokenCount(at: t0, last: .init(input: n, output: 1), total: .init(input: n * 10, output: n))
    }

    static func followsAppendsToOpenFile() throws {
        let home = try TempHome()
        defer { home.remove() }
        let collected = Collected()
        let monitor = CodexSessionMonitor(environment: home.environment, latency: 0.05) { collected.add($0) }
        monitor.start()
        defer { monitor.stop() }
        Thread.sleep(forTimeInterval: 0.3)

        let writer = try OpenWriter(home.url.appendingPathComponent(CodexRollout.path(id)))
        defer { writer.close() }
        try writer.append([CodexRollout.meta(id: id, at: t0), tokenCount(1)])
        for n in 2...4 {
            Thread.sleep(forTimeInterval: 0.4)
            try writer.append([tokenCount(n)])
        }
        try expect(collected.wait(for: 4), "一直开着的会话记录追加的事件 5 秒内没有全部读入：\(collected.all.count) 条")
        Thread.sleep(forTimeInterval: 0.3)
        try expectEqual(collected.all.map(\.usage?.input), [1, 2, 3, 4])
    }

    static func followsLockedSessionAppends() throws {
        let home = try TempHome()
        defer { home.remove() }
        // 会话记录早就写好、关闭了（App 启动前的会话，resume 时守护进程重新打开它）：修改时间放到很久以前
        let path = CodexRollout.path(id)
        let url = home.url.appendingPathComponent(path)
        try home.write(path, CodexRollout.file([CodexRollout.meta(id: id, at: t0), tokenCount(1)]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)],
                                              ofItemAtPath: url.path)
        try FileManager.default.createDirectory(
            at: home.url.appendingPathComponent(".codex/thread-writer-locks"), withIntermediateDirectories: true)
        let collected = Collected()
        let monitor = CodexSessionMonitor(environment: home.environment, latency: 0.05) { collected.add($0) }
        monitor.start()
        defer { monitor.stop() }
        try expect(collected.wait(for: 1), "启动后 5 秒内没有读入已有的会话记录")
        Thread.sleep(forTimeInterval: 0.3)

        // 守护进程：打开会话记录、拿写入锁（锁文件也一直开着），之后只追加
        let writer = try OpenWriter(url)
        defer { writer.close() }
        let lock = try OpenWriter(home.url.appendingPathComponent(".codex/thread-writer-locks/\(id).lock"))
        defer { lock.close() }
        for n in 2...4 {
            Thread.sleep(forTimeInterval: 0.4)
            try writer.append([tokenCount(n)])
        }
        try expect(collected.wait(for: 4), "拿着写入锁追加的事件 5 秒内没有全部读入：\(collected.all.count) 条")
        Thread.sleep(forTimeInterval: 0.3)
        try expectEqual(collected.all.map(\.usage?.input), [1, 2, 3, 4])
    }
}
