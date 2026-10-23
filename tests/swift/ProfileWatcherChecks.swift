// ticket 06：档案目录、当前档案记录、各档案 .claude.json 变化时，ProfileWatcher 自动通知。
// 用真实文件系统事件（FSEvents），每一步最多等 5 秒。

import Foundation

final class ProfileWatcherChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("档案目录、当前档案记录、.claude.json 变化时都会通知", notifiesOnRelevantChanges),
            Check("档案里的运行时文件变化不通知；stop 之后不再通知", ignoresRuntimeChurnAndStops),
        ]
    }

    /// 记录回调次数（回调在后台队列上发生）
    final class Counter {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }

        /// 等到计数超过 n，返回是否等到
        func wait(beyond n: Int, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if count > n { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return count > n
        }

        /// 等到连续 quiet 秒没有新回调（让上一步的迟到事件落定）
        func settle(quiet: TimeInterval = 0.5) {
            var last = count
            while true {
                Thread.sleep(forTimeInterval: quiet)
                if count == last { return }
                last = count
            }
        }
    }

    private static func expectNotified(_ counter: Counter, _ what: String,
                                       _ action: () throws -> Void) throws {
        counter.settle()
        let before = counter.count
        try action()
        try expect(counter.wait(beyond: before), "\(what) 之后 5 秒内没有收到通知")
    }

    static func notifiesOnRelevantChanges() throws {
        let home = try TempHome()
        defer { home.remove() }
        let counter = Counter()
        // 启动时 ~/.claude-profiles 和 ~/.claude.json 都还不存在
        let watcher = ProfileWatcher(environment: home.environment, latency: 0.05) { counter.increment() }
        watcher.start()
        defer { watcher.stop() }

        try expectNotified(counter, "首次创建档案目录") { try home.makeProfileDir("work") }
        try expectNotified(counter, "原子写入当前档案记录") {
            try Data("work\n".utf8).write(to: home.profilesRoot.appendingPathComponent("active"),
                                          options: .atomic)
        }
        try expectNotified(counter, "写入档案的 .claude.json") {
            try home.writeJSON(".claude-profiles/work/.claude.json", claudeConfig(uuid: "u", email: "a@b.c"))
        }
        try expectNotified(counter, "原子写入默认档案的 .claude.json") {
            try Data("{}".utf8).write(to: home.url.appendingPathComponent(".claude.json"), options: .atomic)
        }
        try expectNotified(counter, "新增第二个档案") { try home.makeProfileDir("personal") }
        try expectNotified(counter, "删除档案目录") {
            try FileManager.default.removeItem(at: home.profilesRoot.appendingPathComponent("personal"))
        }
        try expectNotified(counter, "删除当前档案记录") {
            try FileManager.default.removeItem(at: home.profilesRoot.appendingPathComponent("active"))
        }
    }

    static func ignoresRuntimeChurnAndStops() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfile("work", config: claudeConfig(uuid: "u", email: "a@b.c"))
        let counter = Counter()
        let watcher = ProfileWatcher(environment: home.environment, latency: 0.05) { counter.increment() }
        watcher.start()

        counter.settle()
        var before = counter.count
        try home.write(".claude-profiles/work/history.jsonl", "{}\n")
        try home.write(".claude-profiles/work/sessions/1.json", "{}")
        try home.write("unrelated.txt", "x")
        Thread.sleep(forTimeInterval: 1)
        try expectEqual(counter.count, before, "运行时文件和无关文件的变化不应通知")

        // 确认监听仍在工作，再停止
        try expectNotified(counter, "写入档案的 .claude.json") {
            try home.writeJSON(".claude-profiles/work/.claude.json", claudeConfig(uuid: "v", email: "a@b.c"))
        }
        watcher.stop()
        counter.settle()
        before = counter.count
        try home.makeProfileDir("later")
        Thread.sleep(forTimeInterval: 1)
        try expectEqual(counter.count, before, "stop 之后不应再通知")
    }
}
