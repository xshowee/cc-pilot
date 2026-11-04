// chatgpt-profiles ticket 02：ChatGPT 档案目录、当前档案记录、各档案 auth.json 变化时（ccp chatgpt、
// codex login / logout），ProfileWatcher 的 ChatGPT 模式自动通知。用真实文件系统事件，每一步最多等 5 秒。

import Foundation

final class ChatGPTProfileWatcherChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("档案目录、当前档案记录、auth.json 的登录登出都会通知", notifiesOnRelevantChanges),
            Check("~/.codex 与档案里的运行时文件、Claude 档案的变化都不通知", ignoresRuntimeChurn),
        ]
    }

    typealias Counter = ProfileWatcherChecks.Counter

    static func expectNotified(_ counter: Counter, _ what: String, _ action: () throws -> Void) throws {
        counter.settle()
        let before = counter.count
        try action()
        try expect(counter.wait(beyond: before), "\(what) 之后 5 秒内没有收到通知")
    }

    static func notifiesOnRelevantChanges() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        let counter = Counter()
        // 启动时 ~/.codex-profiles 还不存在
        let watcher = ProfileWatcher(environment: home.environment, latency: 0.05, watching: .chatgptAuth) {
            counter.increment()
        }
        watcher.start()
        defer { watcher.stop() }

        try expectNotified(counter, "默认档案 codex login（写入 ~/.codex/auth.json）") {
            try JSONSerialization.data(withJSONObject: chatgptAuth())
                .write(to: home.url.appendingPathComponent(".codex/auth.json"), options: .atomic)
        }
        try expectNotified(counter, "默认档案 codex logout（删除 auth.json）") {
            try FileManager.default.removeItem(at: home.url.appendingPathComponent(".codex/auth.json"))
        }
        try expectNotified(counter, "首次创建档案目录") { try home.makeCodexProfile("work") }
        try expectNotified(counter, "原子写入当前档案记录") {
            try Data("work\n".utf8).write(to: home.codexProfilesRoot.appendingPathComponent("active"),
                                          options: .atomic)
        }
        try expectNotified(counter, "档案里 codex login") {
            try home.writeJSON(".codex-profiles/work/auth.json", chatgptAuth())
        }
        try expectNotified(counter, "删除档案目录") {
            try FileManager.default.removeItem(at: home.codexProfilesRoot.appendingPathComponent("work"))
        }
    }

    static func ignoresRuntimeChurn() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: chatgptAuth())
        try home.makeCodexProfile("work", auth: chatgptAuth())
        let counter = Counter()
        let watcher = ProfileWatcher(environment: home.environment, latency: 0.05, watching: .chatgptAuth) {
            counter.increment()
        }
        watcher.start()
        defer { watcher.stop() }

        counter.settle()
        let before = counter.count
        try home.write(".codex/sessions/2026/11/04/rollout-1.jsonl", "{}\n")
        try home.write(".codex/history.jsonl", "{}\n")
        try home.write(".codex-profiles/work/.codex-global-state.json", "{}")
        try home.write(".codex-profiles/work/sqlite/codex.db", "x")
        try home.makeProfile("claude-work", config: claudeConfig(uuid: "u", email: "a@b.c"))
        try home.writeDefaultConfig(claudeConfig(uuid: "u", email: "a@b.c"))
        Thread.sleep(forTimeInterval: 1)
        try expectEqual(counter.count, before, "运行时文件和 Claude 档案的变化不应通知")

        try expectNotified(counter, "确认监听仍在工作：档案里 codex logout") {
            try FileManager.default.removeItem(at: home.codexProfilesRoot.appendingPathComponent("work/auth.json"))
        }
    }
}
