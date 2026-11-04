// chatgpt-profiles ticket 08：ChatGPT 实时额度——进行中会话的 token_count.rate_limits 并入它所属账号的额度。
//
// 检查的接口（seam）：
//   ChatGPTLiveQuotaTracker(environment:).update(with: 会话记录读取器读到的事件) → [账号: LiveQuota]
//   UsageBoard.recordLive(_:for:)   按账号并入（与刷新结果同一合并规则）
//   AccountUsage.fiveHour / sevenDay(now:)、fiveHourWindow
// 会话记录与进程都是合成的（CodexRolloutFixtures、FakeCodexProcesses），不发任何请求。
// 期望值手算：剩余 = 100 − 已用，向下取整；合并规则同 Claude（spec "实时额度"）：resets_at 更晚的优先，
// 相同时取已用百分比高的；变灰（30 分钟）按事件自己的时间算。

import Foundation

final class ChatGPTLiveQuotaChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("进行中会话的 rate_limits 并入写它的档案登录的账号；变灰按事件自己的时间算", liveQuotaReachesAccount),
            Check("与刷新合并：resets_at 更晚的优先，相同时取已用高的", mergesWithRefresh),
            Check("归属不到的会话（没有写入进程、外部目录、档案没有账号）不更新任何账号", unattributedUpdatesNothing),
            Check("账号在归属时确定：档案之后换了登录，这个会话的额度仍算旧账号的", accountFixedAtAttribution),
            Check("档案当时没有账号（auth.json 还没写好、会话开始后才登录）：之后有账号了，这个会话照常更新", accountAppearsLater),
            Check("接收实时额度不发请求", sendsNoRequests),
        ]
    }

    static let session = "019a4f00-0000-7000-8000-0000000000a1"
    static let other = "019a4f00-0000-7000-8000-0000000000b2"
    static let resets = 1_800_010_000
    static let weekResets = 1_800_300_000

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// 准备：work 档案登录 user-w（工作区 ws-1），默认档案登录 user-d；一个进程在 work 档案里写 session
    static func prepare(_ home: TempHome) throws {
        try home.makeCodexDefault(auth: chatgptAuth(email: "d@example.com", userID: "user-d", workspaceID: "ws-1"))
        try home.makeCodexProfile("work", auth: chatgptAuth(email: "w@example.com", userID: "user-w", workspaceID: "ws-1"))
        home.codexProcesses.run(pid: 42, home: .path(home.url.path + "/.codex-profiles/work"),
                                files: [home.url.path + "/.codex/thread-writer-locks/\(session).lock"])
    }

    static func writeSession(_ home: TempHome, _ id: String, _ lines: [String]) throws {
        try home.write(CodexRollout.path(id), CodexRollout.file([CodexRollout.meta(id: id, at: iso(fixedNow))] + lines))
    }

    static let workAccount = UsageAccount(id: "chatgpt:user-w:ws-1")
    static let defaultAccount = UsageAccount(id: "chatgpt:user-d:ws-1")

    static func liveQuotaReachesAccount() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepare(home)
        let t1 = fixedNow.addingTimeInterval(60), t2 = fixedNow.addingTimeInterval(120)
        try writeSession(home, session, [
            CodexRollout.tokenCount(at: iso(t1), last: nil,
                                    primary: .init(used: 20, minutes: 300, resetsAt: resets),
                                    secondary: .init(used: 50, minutes: 10080, resetsAt: weekResets)),
            CodexRollout.tokenCount(at: iso(t2), last: .init(input: 10, output: 1),
                                    primary: .init(used: 25.5, minutes: 300, resetsAt: resets),
                                    secondary: .init(used: 51, minutes: 10080, resetsAt: weekResets)),
        ])
        let events = CodexSessionReader(environment: home.environment).scan([:]).events
        let quotas = ChatGPTLiveQuotaTracker(environment: home.environment).update(with: events)
        try expectEqual(Array(quotas.keys), [workAccount])
        var board = UsageBoard()
        for (account, quota) in quotas { board.recordLive(quota, for: account) }
        let usage = try unwrap(board.usage(for: workAccount))
        try expectEqual(usage.fiveHour(now: t2), .remaining(74, tint: .green))
        try expectEqual(usage.sevenDay(now: t2), .remaining(49, tint: .yellow))
        try expectEqual(usage.fiveHourWindow?.observedAt, t2)
        // 变灰按事件时间：事件之后 31 分钟（即使是刚读到的）
        try expectEqual(usage.fiveHour(now: t2.addingTimeInterval(31 * 60)), .remaining(74, tint: .stale))
        try expect(board.usage(for: defaultAccount) == nil, "别的账号不受影响")
    }

    static func mergesWithRefresh() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepare(home)
        let t1 = fixedNow.addingTimeInterval(60)
        var board = UsageBoard()
        // 刷新：5 小时窗口已用 30%（同一窗口），周窗口是上一个窗口的
        board.record(UsageRefreshOutcome(account: workAccount, result: .success(UsageSnapshot(
            fiveHour: UsageWindow(utilization: 30, resetsAt: Date(timeIntervalSince1970: TimeInterval(resets))),
            sevenDay: UsageWindow(utilization: 90, resetsAt: Date(timeIntervalSince1970: TimeInterval(weekResets - 604_800))),
            fetchedAt: fixedNow))))
        try writeSession(home, session, [
            CodexRollout.tokenCount(at: iso(t1), last: nil,
                                    primary: .init(used: 20, minutes: 300, resetsAt: resets),
                                    secondary: .init(used: 5, minutes: 10080, resetsAt: weekResets)),
        ])
        let events = CodexSessionReader(environment: home.environment).scan([:]).events
        for (account, quota) in ChatGPTLiveQuotaTracker(environment: home.environment).update(with: events) {
            board.recordLive(quota, for: account)
        }
        let usage = try unwrap(board.usage(for: workAccount))
        try expectEqual(usage.fiveHour(now: t1), .remaining(70, tint: .green), "同一窗口取已用高的（刷新的 30%）")
        try expectEqual(usage.sevenDay(now: t1), .remaining(95, tint: .green), "resets_at 更晚的优先（实时的新窗口）")
        try expectEqual(usage.sevenDayWindow?.source, .live)
    }

    static func unattributedUpdatesNothing() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepare(home)
        try home.makeCodexProfile("empty")  // 没登录
        let lock = { (id: String) in home.url.path + "/.codex/thread-writer-locks/\(id).lock" }
        let external = "019a4f00-0000-7000-8000-0000000000c3"
        let loggedOut = "019a4f00-0000-7000-8000-0000000000d4"
        home.codexProcesses.run(pid: 43, home: .path("/opt/codex-home"), files: [lock(external)])
        home.codexProcesses.run(pid: 44, home: .path(home.url.path + "/.codex-profiles/empty"), files: [lock(loggedOut)])
        let limits = CodexRollout.tokenCount(at: iso(fixedNow.addingTimeInterval(60)), last: nil,
                                             primary: .init(used: 20, minutes: 300, resetsAt: resets))
        for id in [other, external, loggedOut] { try writeSession(home, id, [limits]) }
        let events = CodexSessionReader(environment: home.environment).scan([:]).events
        try expectEqual(events.count, 3)
        let quotas = ChatGPTLiveQuotaTracker(environment: home.environment).update(with: events)
        try expect(quotas.isEmpty, "得到 \(quotas)")
    }

    static func accountFixedAtAttribution() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepare(home)
        let reader = CodexSessionReader(environment: home.environment)
        let tracker = ChatGPTLiveQuotaTracker(environment: home.environment)
        let t1 = fixedNow.addingTimeInterval(60), t2 = fixedNow.addingTimeInterval(120)
        try writeSession(home, session, [
            CodexRollout.tokenCount(at: iso(t1), last: nil, primary: .init(used: 20, minutes: 300, resetsAt: resets)),
        ])
        let scan1 = reader.scan([:])
        try expectEqual(Array(tracker.update(with: scan1.events).keys), [workAccount])

        // work 档案换成另一个账号登录；运行中的进程继续写同一个会话
        try home.writeJSON(".codex-profiles/work/auth.json",
                           chatgptAuth(email: "n@example.com", userID: "user-n", workspaceID: "ws-2"))
        let handle = try FileHandle(forWritingTo: home.url.appendingPathComponent(CodexRollout.path(session)))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((CodexRollout.tokenCount(
            at: iso(t2), last: nil, primary: .init(used: 22, minutes: 300, resetsAt: resets)) + "\n").utf8))
        try handle.close()
        let quotas = tracker.update(with: reader.scan(scan1.cursors).events)
        try expectEqual(Array(quotas.keys), [workAccount])
        try expectEqual(quotas[workAccount]?.fiveHour?.utilization, 22)
    }

    static func accountAppearsLater() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepare(home)
        try home.makeCodexProfile("late")  // 会话开始时还没登录
        home.codexProcesses.run(pid: 45, home: .path(home.url.path + "/.codex-profiles/late"),
                                files: [home.url.path + "/.codex/thread-writer-locks/\(other).lock"])
        let reader = CodexSessionReader(environment: home.environment)
        let tracker = ChatGPTLiveQuotaTracker(environment: home.environment)
        let t1 = fixedNow.addingTimeInterval(60), t2 = fixedNow.addingTimeInterval(120)
        try writeSession(home, other, [
            CodexRollout.tokenCount(at: iso(t1), last: nil, primary: .init(used: 20, minutes: 300, resetsAt: resets)),
        ])
        let scan1 = reader.scan([:])
        try expect(tracker.update(with: scan1.events).isEmpty, "还没有账号时不更新")

        try home.writeJSON(".codex-profiles/late/auth.json",
                           chatgptAuth(email: "l@example.com", userID: "user-l", workspaceID: "ws-1"))
        let handle = try FileHandle(forWritingTo: home.url.appendingPathComponent(CodexRollout.path(other)))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((CodexRollout.tokenCount(
            at: iso(t2), last: nil, primary: .init(used: 22, minutes: 300, resetsAt: resets)) + "\n").utf8))
        try handle.close()
        let quotas = tracker.update(with: reader.scan(scan1.cursors).events)
        let late = UsageAccount(id: "chatgpt:user-l:ws-1")
        try expectEqual(Array(quotas.keys), [late])
        try expectEqual(quotas[late]?.fiveHour?.utilization, 22)
    }

    static func sendsNoRequests() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepare(home)
        try writeSession(home, session, [
            CodexRollout.tokenCount(at: iso(fixedNow), last: nil, primary: .init(used: 20, minutes: 300, resetsAt: resets)),
        ])
        let events = CodexSessionReader(environment: home.environment).scan([:]).events
        var board = UsageBoard()
        for (account, quota) in ChatGPTLiveQuotaTracker(environment: home.environment).update(with: events) {
            board.recordLive(quota, for: account)
        }
        try expectEqual(home.transport.requestCount, 0)
        try expect(board.usage(for: workAccount)?.problem == nil, "不碰失败原因")
    }
}
