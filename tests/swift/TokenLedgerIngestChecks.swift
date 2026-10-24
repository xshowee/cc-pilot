// token-usage ticket 01：把会话记录增量读进 cc-pilot 自己的账本，按 message.id 跨文件去重。
// 会话记录都是合成的，写在临时主目录的 .claude/projects/ 下。

import Foundation

final class TokenLedgerIngestChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("账本放在 ~/Library/Application Support/cc-pilot/ 下", ledgerLivesInApplicationSupport),
            Check("同一消息写成多行只记一次；没有 message.id 的行照常计入；<synthetic> 不计", dedupsWithinFile),
            Check("同一 message.id 出现在 resume 出来的另一份文件里，只记一次", dedupsAcrossFiles),
            Check("子代理会话记录也读，并记下父会话", readsSubagentTranscripts),
            Check("只读新追加的部分；写到一半的最后一行下次再读", readsIncrementallyAndWaitsForHalfLine),
            Check("重新打开账本再读不会重复计入；会话记录被删除不影响账本", survivesReopenAndDeletion),
        ]
    }

    static let t0 = "2026-10-20T10:00:00.000Z"

    static func ledgerLivesInApplicationSupport() throws {
        let home = try TempHome()
        defer { home.remove() }
        let url = TokenLedger.defaultURL(environment: home.environment)
        try expectEqual(url.path, home.url.path + "/Library/Application Support/cc-pilot/token-usage.sqlite")
        _ = try TokenLedger(at: url)
        try expect(FileManager.default.fileExists(atPath: url.path), "打开账本后应创建文件")
    }

    static func dedupsWithinFile() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.transcript("-Users-tester-project/s-1.jsonl", [
            TranscriptFixture.user(session: "s-1", at: t0),
            // 一条消息按 content block 写成三行，每行重复同一份 usage
            TranscriptFixture.assistant(id: "msg_a", session: "s-1", at: t0, input: 10, output: 5,
                                        cacheWrite: 100, cacheRead: 1000, text: "思考"),
            TranscriptFixture.assistant(id: "msg_a", session: "s-1", at: t0, input: 10, output: 5,
                                        cacheWrite: 100, cacheRead: 1000, text: "回答"),
            TranscriptFixture.assistant(id: "msg_a", session: "s-1", at: t0, input: 10, output: 5,
                                        cacheWrite: 100, cacheRead: 1000, text: "工具调用"),
            TranscriptFixture.assistant(id: nil, session: "s-1", at: t0, output: 1),
            TranscriptFixture.assistant(id: nil, session: "s-1", at: t0, output: 1),
            TranscriptFixture.assistant(id: "msg_syn", session: "s-1", model: "<synthetic>", at: t0, output: 99),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        let messages = try env.ledger.messages()
        try expectEqual(messages.count, 3)
        try expectEqual(sum(messages), TokenCounts(input: 10, output: 7, cacheWrite: 100, cacheRead: 1000))
        let a = try unwrap(messages.first { $0.messageID == "msg_a" })
        try expectEqual(a.sessionID, "s-1")
        try expect(a.parentSessionID == nil, "主会话记录没有父会话")
        try expectEqual(a.model, "claude-opus-5-5")
        try expectEqual(a.timestamp, Date(timeIntervalSince1970: 1_792_490_400))
        try expectEqual(a.attribution, .pending)
    }

    static func dedupsAcrossFiles() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.transcript("-Users-tester-project/s-1.jsonl", [
            TranscriptFixture.assistant(id: "msg_a", session: "s-1", at: t0, output: 5),
        ])
        try env.transcript("-Users-tester-project/s-2.jsonl", [
            // resume 出来的新会话把旧消息原样带过来
            TranscriptFixture.assistant(id: "msg_a", session: "s-2", at: t0, output: 5),
            TranscriptFixture.assistant(id: "msg_b", session: "s-2", at: t0, output: 7),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        // 第二份文件晚些时候才继续追加同一条消息，也不重复
        try env.append("-Users-tester-project/s-1.jsonl", [
            TranscriptFixture.assistant(id: "msg_b", session: "s-1", at: t0, output: 7),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        let messages = try env.ledger.messages()
        try expectEqual(messages.compactMap(\.messageID).sorted(), ["msg_a", "msg_b"])
        try expectEqual(sum(messages).output, 12)
    }

    static func readsSubagentTranscripts() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.transcript("-Users-tester-project/parent-1.jsonl", [
            TranscriptFixture.assistant(id: "msg_p", session: "parent-1", at: t0, output: 1),
        ])
        try env.transcript("-Users-tester-project/parent-1/subagents/agent-abc.jsonl", [
            TranscriptFixture.assistant(id: "msg_sub", session: "agent-session-x", at: t0, output: 2),
        ])
        // 会话目录里别的文件（工具输出等）不是会话记录
        try env.transcript("-Users-tester-project/parent-1/tool-results/out.jsonl", [
            TranscriptFixture.assistant(id: "msg_other", session: "parent-1", at: t0, output: 4),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        let messages = try env.ledger.messages()
        try expectEqual(messages.compactMap(\.messageID).sorted(), ["msg_p", "msg_sub"])
        let sub = try unwrap(messages.first { $0.messageID == "msg_sub" })
        try expectEqual(sub.sessionID, "agent-session-x")
        try expectEqual(sub.parentSessionID, "parent-1")
        try expectEqual(sub.attributionSessionID, "parent-1")
    }

    static func readsIncrementallyAndWaitsForHalfLine() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        let full = TranscriptFixture.assistant(id: "msg_b", session: "s-1", at: t0, output: 20)
        let cut = full.index(full.startIndex, offsetBy: full.count / 2)
        try env.transcript("-Users-tester-project/s-1.jsonl", [
            TranscriptFixture.assistant(id: "msg_a", session: "s-1", at: t0, output: 10),
        ])
        try env.appendRaw("-Users-tester-project/s-1.jsonl", String(full[..<cut]))
        try env.ledger.ingest(projectsRoot: env.projects)
        try expectEqual(try env.ledger.messages().compactMap(\.messageID), ["msg_a"], "半截行不应读入")

        try env.appendRaw("-Users-tester-project/s-1.jsonl", String(full[cut...]) + "\n")
        try env.append("-Users-tester-project/s-1.jsonl", [
            TranscriptFixture.assistant(id: nil, session: "s-1", at: t0, output: 1),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        let messages = try env.ledger.messages()
        try expectEqual(messages.count, 3)
        try expectEqual(sum(messages).output, 31)
    }

    static func survivesReopenAndDeletion() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.transcript("-Users-tester-project/s-1.jsonl", [
            TranscriptFixture.assistant(id: "msg_a", session: "s-1", at: t0, output: 10),
            TranscriptFixture.assistant(id: nil, session: "s-1", at: t0, output: 1),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)

        // App 重启：重新打开同一个账本文件再读，没有 message.id 的行也不能再记一次
        let reopened = try TokenLedger(at: env.ledgerURL)
        try reopened.ingest(projectsRoot: env.projects)
        try expectEqual(sum(try reopened.messages()).output, 11)

        // Claude Code 清理了过期的会话记录
        try FileManager.default.removeItem(at: env.projects.appendingPathComponent("-Users-tester-project/s-1.jsonl"))
        try reopened.ingest(projectsRoot: env.projects)
        try expectEqual(sum(try reopened.messages()).output, 11)
    }

    static func sum(_ messages: [LedgerMessage]) -> TokenCounts {
        messages.reduce(.zero) { $0 + $1.tokens }
    }
}

/// 一个临时主目录 + 其中的账本，会话记录写在 .claude/projects/ 下
final class LedgerEnv {
    let home: TempHome
    let ledgerURL: URL
    let ledger: TokenLedger

    init() throws {
        home = try TempHome()
        ledgerURL = TokenLedger.defaultURL(environment: home.environment)
        ledger = try TokenLedger(at: ledgerURL)
    }

    func remove() { home.remove() }

    var projects: URL { home.url.appendingPathComponent(".claude/projects") }

    /// 写一份会话记录（路径相对于 projects/）
    func transcript(_ path: String, _ lines: [String]) throws {
        try home.write(".claude/projects/" + path, TranscriptFixture.file(lines))
    }

    /// 往会话记录末尾追加若干行
    func append(_ path: String, _ lines: [String]) throws {
        try appendRaw(path, TranscriptFixture.file(lines))
    }

    /// 往会话记录末尾追加任意文本（可以是半截行）
    func appendRaw(_ path: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: projects.appendingPathComponent(path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
