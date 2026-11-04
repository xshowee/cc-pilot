// chatgpt-profiles ticket 08：启动时全量读一次 ChatGPT 会话记录，之后监听两个会话目录的变化（FSEvents）增量读入。
// 接口：CodexSessionMonitor(environment:latency:onScan:).start()；directories(for:)（事件 → 要扫描的目录）。
// 用真实文件系统事件，每一步最多等 5 秒。会话记录是合成的。

import CoreServices
import Foundation

final class CodexSessionMonitorChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("启动时读入已有的会话记录；之后追加的事件自动读入，不重复", backfillsThenFollows),
            Check("会话目录启动时还不存在，之后创建也能读入", picksUpRootsCreatedLater),
            Check("只扫描事件报告的目录；根目录本身变化或要求重新扫描时全量", scopesToReportedDirectories),
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
}
