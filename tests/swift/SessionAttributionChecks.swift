// token-usage ticket 02：账本里的明细按 会话 ID → 档案（各档案自己的 history.jsonl）→ 档案读入时登录的账号 归属。
// 用合成的会话记录和 history.jsonl，假的 HOME；不涉及文件监听（见 TokenUsageRecorderChecks）。

import Foundation

final class SessionAttributionChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("登录同一账号的多个档案的会话归到同一个账号", mergesProfilesOfSameAccount),
            Check("档案换登录后，新消息算新账号，旧记录仍算原账号", loginChangeKeepsOldRecords),
            Check("子代理会话记录随父会话归属", subagentsFollowParent),
            Check("history.jsonl 条目晚于消息出现：先等着，条目出现后再归属", waitsForLateHistoryEntry),
            Check("过了等待期仍找不到归属的记为未归属，不计入任何账号", unknownSessionBecomesUnattributed),
            Check("档案读不出账号时先等着，等待期内恢复就归属", waitsWhileAccountUnreadable),
            Check("同一会话出现在几个档案的 history.jsonl 里：取最新一行所在的档案", newestHistoryEntryWins),
        ]
    }

    static let t0 = "2026-10-20T01:00:00Z"
    static let account1 = claudeConfig(uuid: "u-1", email: "one@example.com")
    static let account2 = claudeConfig(uuid: "u-2", email: "two@example.com")

    static func mergesProfilesOfSameAccount() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.home.writeDefaultConfig(account1)
        try env.home.makeProfile("work", config: account1)
        try env.history(nil, [HistoryFixture.prompt(session: "s-default", at: t0)])
        try env.history("work", [HistoryFixture.prompt(session: "s-work", at: t0)])
        try env.transcript("p/s-default.jsonl", [TranscriptFixture.assistant(id: "m1", session: "s-default", at: t0)])
        try env.transcript("p/s-work.jsonl", [TranscriptFixture.assistant(id: "m2", session: "s-work", at: t0)])
        try env.ledger.ingest(projectsRoot: env.projects)

        try SessionAttribution(environment: env.home.environment, now: { date(t0) }).attribute(env.ledger)
        try expectEqual(try attributions(env), [
            "m1": .attributed(profile: "default", account: "account:u-1"),
            "m2": .attributed(profile: "work", account: "account:u-1"),
        ])
    }

    static func loginChangeKeepsOldRecords() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.home.makeProfile("work", config: account1)
        try env.history("work", [HistoryFixture.prompt(session: "s-1", at: t0)])
        try env.transcript("p/s-1.jsonl", [TranscriptFixture.assistant(id: "m1", session: "s-1", at: t0)])
        let attribution = SessionAttribution(environment: env.home.environment, now: { date(t0) })
        try env.ledger.ingest(projectsRoot: env.projects)
        try attribution.attribute(env.ledger)

        try env.home.writeJSON(".claude-profiles/work/.claude.json", account2)
        try env.append("p/s-1.jsonl", [TranscriptFixture.assistant(id: "m2", session: "s-1", at: t0)])
        try env.ledger.ingest(projectsRoot: env.projects)
        try attribution.attribute(env.ledger)
        try expectEqual(try attributions(env), [
            "m1": .attributed(profile: "work", account: "account:u-1"),
            "m2": .attributed(profile: "work", account: "account:u-2"),
        ])
    }

    static func subagentsFollowParent() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.home.makeProfile("work", config: account1)
        try env.history("work", [HistoryFixture.prompt(session: "parent", at: t0)])
        // 子代理的 sessionId 不在任何 history.jsonl 里，只能靠路径上的父会话
        try env.transcript("p/parent/subagents/agent-a.jsonl", [
            TranscriptFixture.assistant(id: "m1", session: "agent-a", at: t0),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        try SessionAttribution(environment: env.home.environment, now: { date(t0) }).attribute(env.ledger)
        try expectEqual(try attributions(env), ["m1": .attributed(profile: "work", account: "account:u-1")])
    }

    static func waitsForLateHistoryEntry() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.home.makeProfile("work", config: account1)
        try env.history("work", [HistoryFixture.prompt(session: "other", at: t0)])
        try env.transcript("p/s-1.jsonl", [TranscriptFixture.assistant(id: "m1", session: "s-1", at: t0)])
        let clock = Clock(date(t0, plus: 30))
        let attribution = SessionAttribution(environment: env.home.environment, now: { clock.now })
        try env.ledger.ingest(projectsRoot: env.projects)
        try attribution.attribute(env.ledger)
        try expectEqual(try attributions(env), ["m1": .pending], "条目还没写出来，不能过早判为未归属")

        clock.now = date(t0, plus: 60)
        try env.history("work", [HistoryFixture.prompt(session: "s-1", at: t0)])
        try attribution.attribute(env.ledger)
        try expectEqual(try attributions(env), ["m1": .attributed(profile: "work", account: "account:u-1")])
    }

    static func unknownSessionBecomesUnattributed() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.home.makeProfile("work", config: account1)
        try env.history("work", [HistoryFixture.prompt(session: "s-known", at: t0)])
        try env.transcript("p/s-unknown.jsonl", [
            TranscriptFixture.assistant(id: "m1", session: "s-unknown", at: t0, output: 7),
        ])
        try env.transcript("p/s-known.jsonl", [TranscriptFixture.assistant(id: "m2", session: "s-known", at: t0)])
        let clock = Clock(date(t0, plus: SessionAttribution.defaultGrace - 1))
        let attribution = SessionAttribution(environment: env.home.environment, now: { clock.now })
        try env.ledger.ingest(projectsRoot: env.projects)
        try attribution.attribute(env.ledger)
        try expectEqual(try attributions(env)["m1"], .pending)

        clock.now = date(t0, plus: SessionAttribution.defaultGrace + 1)
        try attribution.attribute(env.ledger)
        try expectEqual(try attributions(env), [
            "m1": .unattributed,
            "m2": .attributed(profile: "work", account: "account:u-1"),
        ])
        // 未归属的用量照样记账，汇总时进 account 为空的一行，不进任何账号
        try env.ledger.rollUp(now: date(t0, plus: 40 * 86400), retentionDays: 35,
                              calendar: Calendar(identifier: .gregorian))
        try expectEqual(try env.ledger.dailyUsage().filter { $0.account == nil }.map(\.tokens.output), [7])
    }

    static func waitsWhileAccountUnreadable() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.home.makeProfileDir("work")
        try env.home.write(".claude-profiles/work/.claude.json", "{\"oauthAccount\": ")  // 正被重写
        try env.history("work", [HistoryFixture.prompt(session: "s-1", at: t0)])
        try env.transcript("p/s-1.jsonl", [TranscriptFixture.assistant(id: "m1", session: "s-1", at: t0)])
        let clock = Clock(date(t0, plus: 30))
        let attribution = SessionAttribution(environment: env.home.environment, now: { clock.now })
        try env.ledger.ingest(projectsRoot: env.projects)
        try attribution.attribute(env.ledger)
        try expectEqual(try attributions(env), ["m1": .pending])

        try env.home.writeJSON(".claude-profiles/work/.claude.json", account2)
        try attribution.attribute(env.ledger)
        try expectEqual(try attributions(env), ["m1": .attributed(profile: "work", account: "account:u-2")])
    }

    static func newestHistoryEntryWins() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.home.writeDefaultConfig(account1)
        try env.home.makeProfile("work", config: account2)
        // 在默认档案里开始，之后在 work 里 resume 同一个会话
        try env.history(nil, [HistoryFixture.prompt(session: "s-1", at: "2026-10-20T01:00:00Z")])
        try env.history("work", [HistoryFixture.prompt(session: "s-1", at: "2026-10-20T02:00:00Z")])
        try env.transcript("p/s-1.jsonl", [
            TranscriptFixture.assistant(id: "m1", session: "s-1", at: "2026-10-20T02:00:05Z"),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        try SessionAttribution(environment: env.home.environment, now: { date(t0) }).attribute(env.ledger)
        try expectEqual(try attributions(env), ["m1": .attributed(profile: "work", account: "account:u-2")])
    }

    // MARK: - 辅助

    final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    static func date(_ iso: String, plus seconds: TimeInterval = 0) -> Date {
        TranscriptLine.parseTimestamp(iso)!.addingTimeInterval(seconds)
    }

    static func attributions(_ env: LedgerEnv) throws -> [String: LedgerAttribution] {
        Dictionary(uniqueKeysWithValues: try env.ledger.messages().map { ($0.messageID ?? "", $0.attribution) })
    }
}

/// 合成的 history.jsonl 一行（用户每提交一次输入记一行），模仿真实格式；timestamp 是毫秒
enum HistoryFixture {
    static func prompt(session: String, at timestamp: String, text: String = "你好") -> String {
        let ms = Int(TranscriptLine.parseTimestamp(timestamp)!.timeIntervalSince1970 * 1000)
        let object: [String: Any] = [
            "display": text, "pastedContents": [String: Any](), "timestamp": ms,
            "project": "/Users/tester/project", "sessionId": session,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension LedgerEnv {
    /// 往某个档案的 history.jsonl 末尾追加若干行（profile 为 nil 是默认档案的 ~/.claude/history.jsonl）
    func history(_ profile: String?, _ lines: [String]) throws {
        let relative = profile.map { ".claude-profiles/\($0)/history.jsonl" } ?? ".claude/history.jsonl"
        let file = home.url.appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: file.path) {
            try home.write(relative, TranscriptFixture.file(lines))
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(TranscriptFixture.file(lines).utf8))
    }
}
