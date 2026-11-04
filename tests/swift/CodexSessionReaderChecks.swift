// chatgpt-profiles ticket 08：ChatGPT 会话记录的唯一读取器（09 的 Token 账本复用它）。
// 接口：CodexSessionReader(environment:).scan(_ cursors:under:) → CodexSessionScan
//   { cursors（下次传回来，09 可持久化）, sessions（各文件自己的 session_meta）, events（token_count 事件）, deferred }。
// 会话记录都是合成的（CodexRolloutFixtures.swift），写在临时主目录的 .codex/ 下。
// 期望值来源：夹具里写下的字面值；窗口按 spec "会话记录、账本与归属"（window_minutes 300 / 10080）。

import Foundation

final class CodexSessionReaderChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("读出会话的 session_meta 与每个 token_count 事件（last_token_usage、模型、时间、会话 ID）",
                  readsMetaAndTokenCounts),
            Check("只读新追加的完整行；写到一半的最后一行下次再读；模型等上下文接着用", readsIncrementally),
            Check("文件被重写（变短或换了 inode）时从头读", rereadsRewrittenFile),
            Check(".zst 会话记录整份解压读出；没变时不重读；写到一半（截断）时位置不动、下次再读", readsZst),
            Check("损坏的 .zst（不是截断）不反复重读：记下位置跳过，文件变了才再读", skipsCorruptZst),
            Check("只读 ~/.codex 的 sessions 与 archived_sessions 各一次，不进档案里指向它们的软链接", readsSharedRootsOnce),
            Check("只扫描给出的目录：别处的位置原样保留；扫描过的目录里删掉的文件位置被忘掉", scansOnlyGivenDirectories),
            Check("给出的目录互相包含（同一批变化报告了父目录与子目录）时每份文件只读一次", readsNestedDirectoriesOnce),
            Check("fork 重放的父会话事件、重复写的同一事件去重键相同；之后的新事件去重键不同", deduplicationKeys),
            Check("没带历史的子代理按自己的会话去重：两个子代理首轮用量相同也不合并", subagentsKeyedByOwnSession),
            Check("fork 重放结束（自己的回合开始）后按自己的会话去重：与父会话之后用量相同的事件不合并；重放的标为重放",
                  forkOwnEventsKeyedByOwnSession),
            Check("fork 的 fork：重放里套着的祖父会话、父会话的事件各与原文件的去重键相同", nestedForkReplay),
            Check("窗口按 window_minutes 识别（不按 primary / secondary）；其他长度、其他 limit_id 不算", identifiesWindows),
        ]
    }

    static let t0 = "2026-11-04T10:00:00.000Z"
    static let t1 = "2026-11-04T10:01:00.000Z"
    static let t2 = "2026-11-04T10:02:00.000Z"
    static let t3 = "2026-11-04T10:03:00.000Z"
    /// t0 的秒级时间戳（2026-11-04T10:00:00Z）
    static let t0Seconds: TimeInterval = 1_793_786_400

    static let sessionA = "019a4f00-0000-7000-8000-00000000000a"
    static let sessionB = "019a4f00-0000-7000-8000-00000000000b"

    static func readsMetaAndTokenCounts() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(CodexRollout.path(sessionA), CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: t0, creatorAccountID: "ws-1", creatorUserID: "user-1",
                              originator: "codex_cli_rs"),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t0),
            CodexRollout.userMessage(at: t0),
            // 会话刚开始：只有 rate_limits，没有用量
            CodexRollout.tokenCount(at: t0, last: nil,
                                    primary: .init(used: 10, minutes: 300, resetsAt: 1_793_800_000),
                                    secondary: .init(used: 40, minutes: 10080, resetsAt: 1_794_300_000)),
            CodexRollout.tokenCount(at: t1, last: .init(input: 1200, cached: 1000, output: 30, reasoning: 20,
                                                        cacheWrite: 7),
                                    primary: .init(used: 11, minutes: 300, resetsAt: 1_793_800_000),
                                    secondary: .init(used: 40.5, minutes: 10080, resetsAt: 1_794_300_000)),
        ]))
        let scan = CodexSessionReader(environment: home.environment).scan([:])

        try expectEqual(scan.sessions, [CodexSessionMeta(id: sessionA, creatorAccountID: "ws-1",
                                                         creatorUserID: "user-1", originator: "codex_cli_rs")])
        try expectEqual(scan.events.count, 2)
        let first = scan.events[0], second = scan.events[1]
        try expectEqual(first.sessionID, sessionA)
        try expect(first.usage == nil, "只有 rate_limits 的事件没有用量")
        try expectEqual(first.rateLimits?.fiveHour, UsageWindow(utilization: 10, resetsAt: Date(timeIntervalSince1970: 1_793_800_000)))
        try expectEqual(second.sessionID, sessionA)
        try expectEqual(second.timestamp, Date(timeIntervalSince1970: t0Seconds + 60))
        try expectEqual(second.model, "gpt-5.3-codex")
        try expectEqual(second.usage, CodexTokenUsage(input: 1200, cachedInput: 1000, cacheWriteInput: 7,
                                                      output: 30, reasoningOutput: 20, total: 1230))
        try expectEqual(second.rateLimits?.fiveHour,
                        UsageWindow(utilization: 11, resetsAt: Date(timeIntervalSince1970: 1_793_800_000)))
        try expectEqual(second.rateLimits?.sevenDay,
                        UsageWindow(utilization: 40.5, resetsAt: Date(timeIntervalSince1970: 1_794_300_000)))
        try expect(first.deduplicationKey != second.deduplicationKey, "不同事件的去重键不同")
    }

    // MARK: 增量

    static func readsIncrementally() throws {
        let home = try TempHome()
        defer { home.remove() }
        let path = CodexRollout.path(sessionA)
        let file = home.url.appendingPathComponent(path).path
        let first = CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: t0),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t0),
            CodexRollout.tokenCount(at: t1, last: .init(input: 100, output: 10)),
        ])
        let second = CodexRollout.tokenCount(at: t2, last: .init(input: 200, output: 20),
                                             total: .init(input: 300, output: 30))
        // 第二个事件只写了一半
        try home.write(path, first + String(second.prefix(40)))
        let reader = CodexSessionReader(environment: home.environment)
        let scan1 = reader.scan([:])
        try expectEqual(scan1.events.map(\.usage?.input), [100])
        try expectEqual(scan1.sessions.map(\.id), [sessionA])

        try home.write(path, first + second + "\n")
        let scan2 = reader.scan(scan1.cursors)
        try expectEqual(scan2.events.map(\.usage?.input), [200])
        try expectEqual(scan2.events.first?.model, "gpt-5.3-codex")
        try expectEqual(scan2.events.first?.sessionID, sessionA)
        try expect(scan2.sessions.isEmpty, "session_meta 只在第一次读到时报告")
        try expectEqual(scan2.cursors[file]?.offset, (first + second + "\n").utf8.count)

        let scan3 = reader.scan(scan2.cursors)
        try expect(scan3.events.isEmpty, "没有新内容时什么都不报告")
        try expectEqual(scan3.cursors, scan2.cursors)
    }

    static func rereadsRewrittenFile() throws {
        let home = try TempHome()
        defer { home.remove() }
        let path = CodexRollout.path(sessionA)
        try home.write(path, CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: t0),
            CodexRollout.turnContext(model: "gpt-old", at: t0),
            CodexRollout.tokenCount(at: t1, last: .init(input: 100, output: 10)),
            CodexRollout.tokenCount(at: t2, last: .init(input: 100, output: 10), total: .init(input: 200, output: 20)),
        ]))
        let reader = CodexSessionReader(environment: home.environment)
        let scan1 = reader.scan([:])
        // 重写成更短的内容（新文件、没有 turn_context）：从头读，旧的模型不能带过来
        try FileManager.default.removeItem(at: home.url.appendingPathComponent(path))
        try home.write(path, CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: t0),
            CodexRollout.tokenCount(at: t3, last: .init(input: 7, output: 1)),
        ]))
        let scan2 = reader.scan(scan1.cursors)
        try expectEqual(scan2.events.map(\.usage?.input), [7])
        try expect(scan2.events.first?.model == nil, "重写后的文件里还没有 turn_context")
        try expectEqual(scan2.sessions.map(\.id), [sessionA])
    }

    // MARK: .zst

    static func readsZst() throws {
        let home = try TempHome()
        defer { home.remove() }
        let content = Data(CodexRollout.file([
            CodexRollout.meta(id: sessionB, at: t0, originator: "Codex Desktop"),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t0),
            CodexRollout.tokenCount(at: t1, last: .init(input: 100, cached: 60, output: 10),
                                    primary: .init(used: 5, minutes: 300, resetsAt: 1_793_800_000)),
            CodexRollout.tokenCount(at: t2, last: .init(input: 50, output: 5), total: .init(input: 150, cached: 60, output: 15)),
        ]).utf8)
        let frame = RawZstdFrame.wrap(content)
        let path = CodexRollout.path(sessionB, root: "archived_sessions", compressed: true)
        let file = home.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 正在写入：只有前一半
        try frame.prefix(frame.count / 2).write(to: file)
        let reader = CodexSessionReader(environment: home.environment)
        let scan1 = reader.scan([:])
        try expect(scan1.events.isEmpty, "截断的 .zst 读不出事件")
        try expectEqual(scan1.deferred, [file.path])
        try expect(scan1.cursors[file.path] == nil, "截断时不记位置")

        try frame.write(to: file)
        let scan2 = reader.scan(scan1.cursors)
        try expectEqual(scan2.deferred, [])
        try expectEqual(scan2.sessions.map(\.originator), ["Codex Desktop"])
        try expectEqual(scan2.events.map(\.usage?.input), [100, 50])
        try expectEqual(scan2.events.map(\.sessionID), [sessionB, sessionB])
        try expectEqual(scan2.events.map(\.model), ["gpt-5.3-codex", "gpt-5.3-codex"])
        try expectEqual(scan2.events.first?.rateLimits?.fiveHour?.utilization, 5)

        let scan3 = reader.scan(scan2.cursors)
        try expect(scan3.events.isEmpty, "没变的 .zst 不重读")
    }

    static func skipsCorruptZst() throws {
        let home = try TempHome()
        defer { home.remove() }
        let content = Data(CodexRollout.file([
            CodexRollout.meta(id: sessionB, at: t0),
            CodexRollout.tokenCount(at: t1, last: .init(input: 100, output: 10)),
        ]).utf8)
        let path = CodexRollout.path(sessionB, root: "archived_sessions", compressed: true)
        let file = home.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 不是 zstd 帧
        try Data("not a zstd frame at all".utf8).write(to: file)
        let reader = CodexSessionReader(environment: home.environment)
        let scan1 = reader.scan([:])
        try expectEqual(scan1.deferred, [], "损坏不是\"稍后再试\"")
        try expect(scan1.events.isEmpty, "损坏的文件读不出事件")
        try expect(scan1.cursors[file.path] != nil, "记下位置，下次跳过")
        try expectEqual(reader.scan(scan1.cursors).deferred, [])

        // 文件被换成好的：再读
        try RawZstdFrame.wrap(content).write(to: file)
        let scan2 = reader.scan(scan1.cursors)
        try expectEqual(scan2.events.map(\.usage?.input), [100])
    }

    // MARK: 目录

    static func readsSharedRootsOnce() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(CodexRollout.path(sessionA), CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: t0),
            CodexRollout.tokenCount(at: t1, last: .init(input: 1, output: 1)),
        ]))
        try home.write(CodexRollout.path(sessionB, root: "archived_sessions", day: "2026/10/01"), CodexRollout.file([
            CodexRollout.meta(id: sessionB, at: t0),
            CodexRollout.tokenCount(at: t1, last: .init(input: 2, output: 2)),
        ]))
        // 写到一半的临时文件、别的文件不读
        try home.write(".codex/sessions/2026/11/04/.rollout-tmp.jsonl", CodexRollout.file([
            CodexRollout.tokenCount(at: t1, last: .init(input: 99, output: 99)),
        ]))
        try home.write(".codex/sessions/notes.jsonl", CodexRollout.file([
            CodexRollout.tokenCount(at: t1, last: .init(input: 98, output: 98)),
        ]))
        // 一个档案按 ADR 0006 布置：会话目录是指向 ~/.codex 的软链接
        let profile = home.url.appendingPathComponent(".codex-profiles/work")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        for dir in ["sessions", "archived_sessions"] {
            try FileManager.default.createSymbolicLink(
                at: profile.appendingPathComponent(dir),
                withDestinationURL: home.url.appendingPathComponent(".codex/\(dir)"))
        }
        // ~/.codex/sessions 里指向别处的软链接目录也不进
        try home.write("elsewhere/rollout-x.jsonl", CodexRollout.file([
            CodexRollout.meta(id: "elsewhere", at: t0),
            CodexRollout.tokenCount(at: t1, last: .init(input: 97, output: 97)),
        ]))
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent(".codex/sessions/link"),
            withDestinationURL: home.url.appendingPathComponent("elsewhere"))

        let scan = CodexSessionReader(environment: home.environment).scan([:])
        try expectEqual(scan.events.map(\.usage?.input).sorted { ($0 ?? 0) < ($1 ?? 0) }, [1, 2])
        try expectEqual(Set(scan.sessions.map(\.id)), [sessionA, sessionB])
        try expect(scan.cursors.keys.allSatisfy { $0.hasPrefix(home.url.path + "/.codex/") }, "位置按 ~/.codex 下的路径记")
    }

    static func scansOnlyGivenDirectories() throws {
        let home = try TempHome()
        defer { home.remove() }
        let today = CodexRollout.path(sessionA)
        let older = CodexRollout.path(sessionB, day: "2026/11/03")
        for (path, id) in [(today, sessionA), (older, sessionB)] {
            try home.write(path, CodexRollout.file([
                CodexRollout.meta(id: id, at: t0),
                CodexRollout.tokenCount(at: t1, last: .init(input: 1, output: 1)),
            ]))
        }
        let reader = CodexSessionReader(environment: home.environment)
        let scan1 = reader.scan([:])
        try expectEqual(scan1.events.count, 2)
        let todayDir = home.url.path + "/.codex/sessions/2026/11/04"
        // 两个文件都追加一个事件，但只扫描今天的目录
        for path in [today, older] {
            let handle = try FileHandle(forWritingTo: home.url.appendingPathComponent(path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((CodexRollout.tokenCount(at: t2, last: .init(input: 5, output: 1),
                                                                       total: .init(input: 6, output: 2)) + "\n").utf8))
            try handle.close()
        }
        let scan2 = reader.scan(scan1.cursors, under: [todayDir])
        try expectEqual(scan2.events.map(\.sessionID), [sessionA])
        let olderFile = home.url.appendingPathComponent(older).path
        try expectEqual(scan2.cursors[olderFile], scan1.cursors[olderFile])
        // 全量扫描时补上另一个目录的新事件，今天的不重复
        let scan3 = reader.scan(scan2.cursors)
        try expectEqual(scan3.events.map(\.sessionID), [sessionB])

        try FileManager.default.removeItem(at: home.url.appendingPathComponent(today))
        let scan4 = reader.scan(scan3.cursors, under: [todayDir])
        try expect(scan4.cursors[home.url.appendingPathComponent(today).path] == nil, "删掉的文件位置被忘掉")
        try expect(scan4.cursors[olderFile] != nil, "没扫描的目录里的位置保留")
    }

    static func readsNestedDirectoriesOnce() throws {
        let home = try TempHome()
        defer { home.remove() }
        let path = CodexRollout.path(sessionA)
        try home.write(path, CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: t0),
            CodexRollout.tokenCount(at: t1, last: .init(input: 1, output: 1)),
        ]))
        let reader = CodexSessionReader(environment: home.environment)
        let scan1 = reader.scan([:])
        let handle = try FileHandle(forWritingTo: home.url.appendingPathComponent(path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((CodexRollout.tokenCount(at: t2, last: .init(input: 2, output: 1),
                                                                   total: .init(input: 3, output: 2)) + "\n").utf8))
        try handle.close()
        // FSEvents 一批里可以同时有新建的日期目录的父目录与追加写入的目录（例如零点新建 2026/11/05 时）
        let sessions = home.url.path + "/.codex/sessions"
        let scan2 = reader.scan(scan1.cursors, under: [sessions + "/2026/11/04", sessions + "/2026/11/",
                                                       sessions + "/2026", sessions + "/2026/11/04/"])
        try expectEqual(scan2.events.map(\.usage?.input), [2])
        let file = home.url.appendingPathComponent(path).path
        try expectEqual(reader.scan(scan2.cursors).events.count, 0, "读过的不再读")
        try expectEqual(scan2.cursors[file], reader.scan(scan2.cursors).cursors[file])
    }

    // MARK: 去重键

    static func deduplicationKeys() throws {
        let home = try TempHome()
        defer { home.remove() }
        let parent = sessionA, child = sessionB
        let e1 = CodexRollout.tokenCount(at: t1, last: .init(input: 100, output: 10))
        let e2 = CodexRollout.tokenCount(at: t2, last: .init(input: 50, output: 5), total: .init(input: 150, output: 15))
        try home.write(CodexRollout.path(parent), CodexRollout.file([
            CodexRollout.meta(id: parent, at: t0),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t0),
            e1,
            // 只更新 rate_limits 时同一份 info 又写了一遍
            CodexRollout.tokenCount(at: t1, last: .init(input: 100, output: 10),
                                    primary: .init(used: 3, minutes: 300, resetsAt: 1_793_800_000)),
            e2,
            // 父会话在 fork 之后继续
            CodexRollout.tokenCount(at: t3, last: .init(input: 40, output: 4), total: .init(input: 190, output: 19)),
        ]))
        // fork：自己的 session_meta → 重放父会话（时间戳是重放时的）→ 自己的新事件
        try home.write(CodexRollout.path(child), CodexRollout.file([
            CodexRollout.meta(id: child, at: t3, forkedFrom: parent),
            CodexRollout.meta(id: parent, at: t3),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t3),
            CodexRollout.tokenCount(at: t3, last: .init(input: 100, output: 10)),
            CodexRollout.tokenCount(at: t3, last: .init(input: 50, output: 5), total: .init(input: 150, output: 15)),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t3),
            CodexRollout.tokenCount(at: t3, last: .init(input: 30, output: 3), total: .init(input: 180, output: 18)),
        ]))
        let scan = CodexSessionReader(environment: home.environment).scan([:])
        let parentKeys = scan.events.filter { $0.sessionID == parent }.map(\.deduplicationKey)
        let childKeys = scan.events.filter { $0.sessionID == child }.map(\.deduplicationKey)
        try expectEqual(parentKeys.count, 4)
        try expectEqual(parentKeys[0], parentKeys[1], "同一事件写两遍，去重键相同")
        try expectEqual(Set(parentKeys).count, 3)
        try expectEqual(childKeys.count, 3)
        try expectEqual(Array(childKeys.prefix(2)), [parentKeys[0], parentKeys[2]], "重放的事件与父会话的去重键相同")
        try expect(!parentKeys.contains(childKeys[2]), "fork 之后自己的新事件去重键不同")
        try expectEqual(scan.sessions.map(\.id).sorted(), [parent, child].sorted())
        try expectEqual(scan.sessions.first { $0.id == child }?.forkedFromID, parent)
    }

    static func subagentsKeyedByOwnSession() throws {
        let home = try TempHome()
        defer { home.remove() }
        let parent = CodexRollout.v7(ms: 1_793_786_400_000)
        let children = [CodexRollout.v7(ms: 1_793_786_460_000, serial: 1), CodexRollout.v7(ms: 1_793_786_460_000, serial: 2)]
        for child in children {
            try home.write(CodexRollout.path(child), CodexRollout.file([
                CodexRollout.meta(id: child, at: t1, parentThread: parent),
                CodexRollout.turnContext(model: "gpt-5.3-codex", at: t1),
                CodexRollout.tokenCount(at: t1, last: .init(input: 100, output: 10)),
            ]))
        }
        let events = CodexSessionReader(environment: home.environment).scan([:]).events
        try expectEqual(events.count, 2)
        try expect(events[0].deduplicationKey != events[1].deduplicationKey,
                   "两个子代理的事件去重键相同：\(events.map(\.deduplicationKey))")
        try expect(!events.contains { $0.replayed }, "子代理自己的事件不是重放")
    }

    static func forkOwnEventsKeyedByOwnSession() throws {
        let home = try TempHome()
        defer { home.remove() }
        let base: UInt64 = 1_793_786_400_000
        let parent = CodexRollout.v7(ms: base), child = CodexRollout.v7(ms: base + 5_000)
        let parentTurn = CodexRollout.v7(ms: base + 1_000, serial: 1)
        let e1 = CodexRollout.tokenCount(at: t1, last: .init(input: 100, output: 10))
        let e2 = CodexRollout.tokenCount(at: t2, last: .init(input: 50, output: 5), total: .init(input: 150, output: 15))
        // 父会话 fork 之后、fork 出来的会话自己：恰好一样的一轮
        let next = { (at: String) in
            CodexRollout.tokenCount(at: at, last: .init(input: 30, output: 3), total: .init(input: 180, output: 18))
        }
        try home.write(CodexRollout.path(parent), CodexRollout.file([
            CodexRollout.meta(id: parent, at: t0),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t0, turnID: parentTurn),
            e1, e2,
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t3, turnID: CodexRollout.v7(ms: base + 10_000, serial: 2)),
            next(t3),
        ]))
        try home.write(CodexRollout.path(child), CodexRollout.file([
            CodexRollout.meta(id: child, at: t3, forkedFrom: parent),
            CodexRollout.meta(id: parent, at: t3),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t3, turnID: parentTurn),
            CodexRollout.tokenCount(at: t3, last: .init(input: 100, output: 10)),
            CodexRollout.tokenCount(at: t3, last: .init(input: 50, output: 5), total: .init(input: 150, output: 15)),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t3, turnID: CodexRollout.v7(ms: base + 5_000, serial: 3)),
            next(t3),
        ]))
        let events = CodexSessionReader(environment: home.environment).scan([:]).events
        let parentKeys = events.filter { $0.sessionID == parent }.map(\.deduplicationKey)
        let childEvents = events.filter { $0.sessionID == child }
        try expectEqual(childEvents.count, 3)
        try expectEqual(childEvents.map(\.replayed), [true, true, false])
        try expectEqual(Array(childEvents.prefix(2).map(\.deduplicationKey)), Array(parentKeys.prefix(2)),
                        "重放的事件与父会话的去重键相同")
        try expect(!parentKeys.contains(childEvents[2].deduplicationKey),
                   "fork 自己的事件与父会话之后用量相同的事件去重键相同：\(childEvents[2].deduplicationKey)")
        try expect(!events.filter { $0.sessionID == parent }.contains { $0.replayed }, "父会话自己的事件不是重放")
    }

    static func nestedForkReplay() throws {
        let home = try TempHome()
        defer { home.remove() }
        let base: UInt64 = 1_793_786_400_000
        let grand = CodexRollout.v7(ms: base), parent = CodexRollout.v7(ms: base + 10_000)
        let child = CodexRollout.v7(ms: base + 20_000)
        let grandTurn = CodexRollout.turnContext(model: "m", at: t0, turnID: CodexRollout.v7(ms: base + 1_000, serial: 1))
        let parentTurn = CodexRollout.turnContext(model: "m", at: t1, turnID: CodexRollout.v7(ms: base + 11_000, serial: 2))
        let childTurn = CodexRollout.turnContext(model: "m", at: t2, turnID: CodexRollout.v7(ms: base + 21_000, serial: 3))
        let g1 = CodexRollout.tokenCount(at: t0, last: .init(input: 100, output: 10))
        let p1 = CodexRollout.tokenCount(at: t1, last: .init(input: 20, output: 2), total: .init(input: 120, output: 12))
        let c1 = CodexRollout.tokenCount(at: t2, last: .init(input: 30, output: 3), total: .init(input: 150, output: 15))
        try home.write(CodexRollout.path(grand), CodexRollout.file([CodexRollout.meta(id: grand, at: t0), grandTurn, g1]))
        try home.write(CodexRollout.path(parent), CodexRollout.file([
            CodexRollout.meta(id: parent, at: t1, forkedFrom: grand),
            CodexRollout.meta(id: grand, at: t1), grandTurn, g1,
            parentTurn, p1,
        ]))
        try home.write(CodexRollout.path(child), CodexRollout.file([
            CodexRollout.meta(id: child, at: t2, forkedFrom: parent),
            CodexRollout.meta(id: parent, at: t2, forkedFrom: grand),
            CodexRollout.meta(id: grand, at: t2), grandTurn, g1,
            parentTurn, p1,
            childTurn, c1,
        ]))
        let events = CodexSessionReader(environment: home.environment).scan([:]).events
        func keys(_ id: String) -> [String] { events.filter { $0.sessionID == id }.map(\.deduplicationKey) }
        try expectEqual(keys(parent).count, 2)
        try expectEqual(keys(child).count, 3)
        try expectEqual(keys(parent)[0], keys(grand)[0], "父会话里重放的祖父会话事件")
        try expectEqual(Array(keys(child).prefix(2)), keys(parent), "子会话里重放的祖父、父会话事件")
        try expectEqual(Set(keys(grand) + keys(parent) + keys(child)).count, 3, "三个不同的事件")
        try expectEqual(events.filter { $0.sessionID == child }.map(\.replayed), [true, true, false])
    }

    // MARK: 窗口

    static func identifiesWindows() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(CodexRollout.path(sessionA), CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: t0),
            // primary 是周窗口、secondary 是 5 小时窗口
            CodexRollout.tokenCount(at: t0, last: nil,
                                    primary: .init(used: 40, minutes: 10080, resetsAt: 1_794_300_000),
                                    secondary: .init(used: 10, minutes: 300, resetsAt: 1_793_800_000)),
            // 旧版本只有 resets_in_seconds：相对事件时间
            CodexRollout.tokenCount(at: t1, last: nil,
                                    primary: .init(used: 12, minutes: 300, resetsInSeconds: 3600)),
            // 认不出的窗口长度：整个 rate_limits 不算
            CodexRollout.tokenCount(at: t2, last: .init(input: 1, output: 1),
                                    primary: .init(used: 99, minutes: 60, resetsAt: 1_793_800_000)),
            // 按模型另计的额度
            CodexRollout.tokenCount(at: t3, last: nil,
                                    primary: .init(used: 77, minutes: 300, resetsAt: 1_793_800_000),
                                    limitID: "codex_other"),
        ]))
        let events = CodexSessionReader(environment: home.environment).scan([:]).events
        try expectEqual(events.count, 3)
        try expectEqual(events[0].rateLimits, CodexRateLimits(
            fiveHour: UsageWindow(utilization: 10, resetsAt: Date(timeIntervalSince1970: 1_793_800_000)),
            sevenDay: UsageWindow(utilization: 40, resetsAt: Date(timeIntervalSince1970: 1_794_300_000))))
        try expectEqual(events[1].rateLimits, CodexRateLimits(
            fiveHour: UsageWindow(utilization: 12, resetsAt: Date(timeIntervalSince1970: t0Seconds + 60 + 3600)),
            sevenDay: nil))
        try expect(events[2].rateLimits == nil, "认不出的窗口不算")
        try expectEqual(events[2].usage?.input, 1)
    }
}
