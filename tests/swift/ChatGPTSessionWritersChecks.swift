// chatgpt-profiles ticket 08：进行中会话的归属——会话由哪个 codex 进程写入，那个进程的 CODEX_HOME 是哪个档案。
// 接口：ChatGPTSessionWriters(environment:).writers(of:) → [会话 ID: ChatGPTSessionWriter]。
// 进程查询是注入的假实现（FakeCodexProcesses），检查绝不查看用户真实的进程。
// 期望值来源：ticket 08（每个进程只读一次环境；只在进程集合变化或出现新会话时查打开的文件）、
// spec "会话 → 档案归属顺序" ①（无 CODEX_HOME 即默认档案）与 "codex 包装函数"（~/.codex-profiles/ 下或等于
// ~/.codex 的才是 cc-pilot 的档案）。

import Foundation

final class ChatGPTSessionWritersChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("打开会话写入锁或会话记录的进程的 CODEX_HOME 决定档案：没有该变量或 ~/.codex 是默认档案，"
                  + "~/.codex-profiles/<名> 是该档案，其他路径是外部目录", mapsWritersToProfiles),
            Check("没有进程打开的会话找不到写入者", sessionWithoutWriter),
            Check("每个进程只读一次环境；只在进程集合变化或出现新会话时查打开的文件", queriesSparingly),
            Check("进程退出后，它写过的会话仍归它的档案；会话被别的档案的进程接着写时改归新档案", followsSessionToNewWriter),
            Check("同一 pid 换了启动时间算新进程，重新读环境", pidReuseIsNewProcess),
        ]
    }

    static let a = "019a4f00-0000-7000-8000-00000000000a"
    static let b = "019a4f00-0000-7000-8000-00000000000b"
    static let c = "019a4f00-0000-7000-8000-00000000000c"
    static let d = "019a4f00-0000-7000-8000-00000000000d"

    static func lock(_ home: TempHome, _ id: String) -> String {
        home.url.path + "/.codex/thread-writer-locks/\(id).lock"
    }

    static func rollout(_ home: TempHome, _ id: String) -> String {
        home.url.appendingPathComponent(CodexRollout.path(id)).path
    }

    static func mapsWritersToProfiles() throws {
        let home = try TempHome()
        defer { home.remove() }
        let fake = home.codexProcesses
        fake.run(pid: 10, home: .unset, files: ["/dev/null", lock(home, a)])
        fake.run(pid: 11, home: .path(home.url.path + "/.codex-profiles/work/"), files: [rollout(home, b)])
        fake.run(pid: 12, home: .path(home.url.path + "/.codex"), files: [lock(home, c)])
        fake.run(pid: 13, home: .path("/opt/elsewhere"), files: [lock(home, d)])
        let writers = ChatGPTSessionWriters(environment: home.environment).writers(of: [a, b, c, d])
        try expectEqual(writers, [a: .profile("default"), b: .profile("work"), c: .profile("default"),
                                  d: .external("/opt/elsewhere")])
    }

    static func sessionWithoutWriter() throws {
        let home = try TempHome()
        defer { home.remove() }
        // 读不出环境的进程（权限、已退出）也不能当默认档案
        home.codexProcesses.run(pid: 10, home: nil, files: [lock(home, b)])
        let writers = ChatGPTSessionWriters(environment: home.environment).writers(of: [a, b])
        try expectEqual(writers, [a: .notFound, b: .notFound])
    }

    static func queriesSparingly() throws {
        let home = try TempHome()
        defer { home.remove() }
        let fake = home.codexProcesses
        let p1 = fake.run(pid: 10, home: .path(home.url.path + "/.codex-profiles/work"), files: [lock(home, a)])
        let writers = ChatGPTSessionWriters(environment: home.environment)

        try expectEqual(writers.writers(of: [a]), [a: .profile("work")])
        try expectEqual(fake.openFileQueries, [p1])
        try expectEqual(fake.environmentReads, [p1])

        // 同一会话再有变化：不再查
        try expectEqual(writers.writers(of: [a]), [a: .profile("work")])
        try expectEqual(fake.openFileQueries.count, 1, "已知会话、进程没变时不查打开的文件")

        // 新会话（这个进程又开了一个）：查一次
        fake.open([lock(home, a), lock(home, b)], in: p1)
        try expectEqual(writers.writers(of: [b]), [b: .profile("work")])
        try expectEqual(fake.openFileQueries.count, 2)

        // 找不到写入者的新会话：查一次，之后进程没变就不再查
        try expectEqual(writers.writers(of: [c]), [c: .notFound])
        try expectEqual(writers.writers(of: [c]), [c: .notFound])
        try expectEqual(fake.openFileQueries.count, 3, "找不到的会话在进程集合不变时只查一次")

        // 新进程出现：重查，它写的会话找到了；老进程的环境不再读
        let p2 = fake.run(pid: 11, home: .unset, files: [lock(home, c)])
        try expectEqual(writers.writers(of: [c]), [c: .profile("default")])
        try expectEqual(Array(fake.openFileQueries.dropFirst(3)), [p1, p2])
        try expectEqual(fake.environmentReads, [p1, p2], "每个进程只读一次环境")
        try expectEqual(writers.writers(of: [a, b, c]), [a: .profile("work"), b: .profile("work"), c: .profile("default")])
        try expectEqual(fake.openFileQueries.count, 5)
    }

    static func followsSessionToNewWriter() throws {
        let home = try TempHome()
        defer { home.remove() }
        let fake = home.codexProcesses
        let p1 = fake.run(pid: 10, home: .path(home.url.path + "/.codex-profiles/work"), files: [lock(home, a)])
        let writers = ChatGPTSessionWriters(environment: home.environment)
        try expectEqual(writers.writers(of: [a]), [a: .profile("work")])

        fake.exit(p1)
        try expectEqual(writers.writers(of: [a]), [a: .profile("work")], "进程退出前写下的事件仍属于它的档案")

        // 共享会话在另一个档案里被 resume
        fake.run(pid: 20, home: .unset, files: [rollout(home, a)])
        try expectEqual(writers.writers(of: [a]), [a: .profile("default")])
    }

    static func pidReuseIsNewProcess() throws {
        let home = try TempHome()
        defer { home.remove() }
        let fake = home.codexProcesses
        let old = fake.run(pid: 10, startedAt: 100, home: .unset, files: [lock(home, a)])
        let writers = ChatGPTSessionWriters(environment: home.environment)
        try expectEqual(writers.writers(of: [a]), [a: .profile("default")])
        fake.exit(old)
        let new = fake.run(pid: 10, startedAt: 200, home: .path(home.url.path + "/.codex-profiles/work"),
                           files: [lock(home, b)])
        try expectEqual(writers.writers(of: [b]), [b: .profile("work")])
        try expectEqual(fake.environmentReads, [old, new])
    }
}
