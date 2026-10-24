// ticket 06：档案目录、当前档案记录、各档案 .claude.json 变化时，ProfileWatcher 自动通知。
// 用真实文件系统事件（FSEvents），每一步最多等 5 秒。

import Foundation

final class ProfileWatcherChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("档案目录、当前档案记录、.claude.json 变化时都会通知", notifiesOnRelevantChanges),
            Check("档案里的运行时文件变化不通知；stop 之后不再通知", ignoresRuntimeChurnAndStops),
            Check("指向别处的软链接档案：登录、登出也会通知（含启动后才建立的软链接）", followsSymlinkedProfiles),
            Check("实时额度文件变化单独通知、合并短时间内的多次写入，不算档案变化", notifiesLiveQuotaSeparately),
        ]
    }

    static func notifiesLiveQuotaSeparately() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        let files = LiveQuotaFiles(environment: home.environment)
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let profiles = Counter(), live = Counter()
        let watcher = ProfileWatcher(environment: home.environment, latency: 0.3,
                                     onLiveQuotaChange: { live.increment() }) { profiles.increment() }
        watcher.start()
        defer { watcher.stop() }
        profiles.settle()
        live.settle()
        let profilesBefore = profiles.count

        // 与转发命令相同的写法：同目录临时文件 + rename，连续写 20 次
        for i in 0..<20 {
            let tmp = files.directory.appendingPathComponent(".work.json.\(i)")
            try Data(#"{"profile":"work","received_at":1,"status":{}}"#.utf8).write(to: tmp)
            _ = rename(tmp.path, files.file(for: "work").path)
        }
        try expect(live.wait(beyond: 0), "写入实时额度文件后 5 秒内没有收到实时额度通知")
        live.settle()
        try expect(live.count < 20, "短时间内的 20 次写入应合并成少数几次通知，实际 \(live.count) 次")
        try expectEqual(profiles.count, profilesBefore, "实时额度文件变化不应触发档案变化通知")

        // 开关文件也在这个目录里：不算档案变化
        try files.setForwardingEnabled(false)
        Thread.sleep(forTimeInterval: 1)
        try expectEqual(profiles.count, profilesBefore, "开关变化不应触发档案变化通知")

        // 档案变化照常通知
        try expectNotified(profiles, "写入档案的 .claude.json") {
            try home.writeJSON(".claude-profiles/work/.claude.json", claudeConfig(uuid: "u", email: "a@b.c"))
        }
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

    static func followsSymlinkedProfiles() throws {
        let home = try TempHome()
        defer { home.remove() }
        let fm = FileManager.default
        // 档案目录在 ~/.claude-profiles 之外，档案根目录里只有指向它的软链接（ProfileStore、ccp ls 都把它当档案）
        let lab = home.root.appendingPathComponent("elsewhere/lab")
        try fm.createDirectory(at: lab, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.profilesRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.profilesRoot.appendingPathComponent("lab"), withDestinationURL: lab)
        let counter = Counter()
        let watcher = ProfileWatcher(environment: home.environment, latency: 0.05) { counter.increment() }
        watcher.start()
        defer { watcher.stop() }

        try expectNotified(counter, "软链接档案登录（写入目标目录里的 .claude.json）") {
            try JSONSerialization.data(withJSONObject: claudeConfig(uuid: "u", email: "a@b.c"))
                .write(to: lab.appendingPathComponent(".claude.json"), options: .atomic)
        }
        try expectNotified(counter, "软链接档案登出") {
            try Data("{}".utf8).write(to: lab.appendingPathComponent(".claude.json"), options: .atomic)
        }

        // 启动之后才建立的软链接档案
        let late = home.root.appendingPathComponent("elsewhere/late")
        try fm.createDirectory(at: late, withIntermediateDirectories: true)
        try expectNotified(counter, "新建软链接档案") {
            try fm.createSymbolicLink(at: home.profilesRoot.appendingPathComponent("late"), withDestinationURL: late)
        }
        try expectNotified(counter, "后建的软链接档案登录") {
            try JSONSerialization.data(withJSONObject: claudeConfig(uuid: "v", email: "c@d.e"))
                .write(to: late.appendingPathComponent(".claude.json"), options: .atomic)
        }

        // 目标目录里的运行时文件同样不通知
        counter.settle()
        let before = counter.count
        try Data("{}\n".utf8).write(to: lab.appendingPathComponent("history.jsonl"))
        Thread.sleep(forTimeInterval: 1)
        try expectEqual(counter.count, before, "软链接档案里的运行时文件变化不应通知")
    }
}
