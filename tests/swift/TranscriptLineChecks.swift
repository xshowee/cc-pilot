// token-usage ticket 01：从会话记录的一行读出 assistant 消息的 token 用量。

import Foundation

final class TranscriptLineChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("assistant 行读出 message.id、时间、会话、模型和四类 token", readsAssistantUsage),
            Check("thinking_tokens 是输出的子集，不另加", thinkingIsPartOfOutput),
            Check("用户消息、<synthetic> 模型、不是 JSON 的行都不算", ignoresNonUsageLines),
            Check("没有 message.id 的行照样读出", keepsLinesWithoutMessageID),
            Check("时间不带毫秒也能读", parsesTimestampWithoutFraction),
            Check("解析前的预筛不漏掉 assistant 行（带空格、换了键的顺序也能读出）", prefilterKeepsAssistantLines),
            Check("usage.iterations 里的每轮 advisor 另读一条，用自己的模型，message.id 加 #advisor<序号>",
                  readsAdvisorIterations),
            Check("iterations 里只有主模型自己的几轮时只读一条（已经在顶层里）", ignoresMainIterations),
        ]
    }

    static func readsAssistantUsage() throws {
        let line = TranscriptFixture.assistant(
            id: "msg_01", session: "s-1", model: "claude-sonnet-4-5-20250929",
            at: "2026-10-20T10:00:00.250Z", input: 3, output: 50, cacheWrite: 100, cacheRead: 200)
        let entry = try unwrap(TranscriptLine.parse(Data(line.utf8)).first)
        try expectEqual(entry.messageID, "msg_01")
        try expectEqual(entry.sessionID, "s-1")
        try expectEqual(entry.model, "claude-sonnet-4-5-20250929")
        try expectEqual(entry.timestamp, Date(timeIntervalSince1970: 1_792_490_400.25))
        try expectEqual(entry.tokens, TokenCounts(input: 3, output: 50, cacheWrite: 100, cacheRead: 200))
        try expectEqual(entry.tokens.total, 353)
    }

    static func thinkingIsPartOfOutput() throws {
        let line = TranscriptFixture.assistant(id: "m", session: "s", at: "2026-10-20T10:00:00.000Z",
                                               input: 1, output: 40, thinking: 30)
        try expectEqual(try unwrap(TranscriptLine.parse(Data(line.utf8)).first).tokens,
                        TokenCounts(input: 1, output: 40, cacheWrite: 0, cacheRead: 0))
    }

    static func ignoresNonUsageLines() throws {
        let user = TranscriptFixture.user(session: "s", at: "2026-10-20T10:00:00.000Z")
        let synthetic = TranscriptFixture.assistant(id: "m", session: "s", model: "<synthetic>",
                                                    at: "2026-10-20T10:00:00.000Z")
        try expect(TranscriptLine.parse(Data(user.utf8)).isEmpty, "用户消息不应读出用量")
        try expect(TranscriptLine.parse(Data(synthetic.utf8)).isEmpty, "<synthetic> 不应计入")
        try expect(TranscriptLine.parse(Data("{\"type\":\"assistant\",\"mess".utf8)).isEmpty, "半截行不应读出")
        try expect(TranscriptLine.parse(Data()).isEmpty, "空行不应读出")
    }

    static func keepsLinesWithoutMessageID() throws {
        let line = TranscriptFixture.assistant(id: nil, session: "s", at: "2026-10-20T10:00:00.000Z", output: 7)
        let entry = try unwrap(TranscriptLine.parse(Data(line.utf8)).first)
        try expect(entry.messageID == nil, "不应凭空造出 message.id")
        try expectEqual(entry.tokens.output, 7)
    }

    static func parsesTimestampWithoutFraction() throws {
        let line = TranscriptFixture.assistant(id: "m", session: "s", at: "2026-10-20T10:00:00Z")
        try expectEqual(try unwrap(TranscriptLine.parse(Data(line.utf8)).first).timestamp,
                        Date(timeIntervalSince1970: 1_792_490_400))
    }

    static func prefilterKeepsAssistantLines() throws {
        let spaced = """
            { "usage_note": 1, "timestamp": "2026-10-20T10:00:00Z", "sessionId": "s", "message": { "model": "m",
              "usage": { "output_tokens": 9 }, "id": "x" }, "type" : "assistant" }
            """
        try expectEqual(try unwrap(TranscriptLine.parse(Data(spaced.utf8)).first).tokens.output, 9)
        // 很长的用户消息（如 tool_result）里提到 assistant、usage 也不会被当成 assistant 行
        let user = TranscriptFixture.user(session: "s", at: "2026-10-20T10:00:00Z",
                                          text: String(repeating: "\"type\":\"assistant\" usage ", count: 1000))
        try expect(TranscriptLine.parse(Data(user.utf8)).isEmpty, "用户消息不应读出用量")
    }

    static func readsAdvisorIterations() throws {
        let line = TranscriptFixture.assistant(
            id: "msg_01", session: "s-1", at: "2026-10-20T10:00:00Z", input: 4, output: 1053,
            cacheWrite: 8430, cacheRead: 209_810,
            advisors: [("claude-fable-5-1", 107_701, 7973), ("claude-fable-5-1", 120_000, 500)])
        let entries = TranscriptLine.parse(Data(line.utf8))
        try expectEqual(entries.map(\.messageID), ["msg_01", "msg_01#advisor0", "msg_01#advisor1"])
        try expectEqual(entries.map(\.model), ["claude-opus-5-5", "claude-fable-5-1", "claude-fable-5-1"])
        try expectEqual(entries[0].tokens, TokenCounts(input: 4, output: 1053, cacheWrite: 8430, cacheRead: 209_810))
        try expectEqual(entries[1].tokens, TokenCounts(input: 107_701, output: 7973, cacheWrite: 0, cacheRead: 0))
        try expect(entries.allSatisfy { $0.sessionID == "s-1" && $0.timestamp == entries[0].timestamp },
                   "advisor 条目沿用这一行的会话和时间")

        let noID = TranscriptFixture.assistant(id: nil, session: "s", at: "2026-10-20T10:00:00Z",
                                               advisors: [("claude-fable-5-1", 1, 2)])
        try expect(TranscriptLine.parse(Data(noID.utf8)).allSatisfy { $0.messageID == nil },
                   "没有 message.id 时 advisor 条目也没有")
    }

    static func ignoresMainIterations() throws {
        let line = """
            {"type":"assistant","sessionId":"s","timestamp":"2026-10-20T10:00:00Z","message":{"id":"m",
             "model":"claude-opus-5-5","usage":{"input_tokens":3,"output_tokens":9,"iterations":[
             {"type":"message","input_tokens":1,"output_tokens":4},{"type":"message","input_tokens":2,"output_tokens":5}]}}}
            """
        let entries = TranscriptLine.parse(Data(line.utf8))
        try expectEqual(entries.count, 1)
        try expectEqual(try unwrap(entries.first).tokens, TokenCounts(input: 3, output: 9, cacheWrite: 0, cacheRead: 0))
    }
}
