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
        ]
    }

    static func readsAssistantUsage() throws {
        let line = TranscriptFixture.assistant(
            id: "msg_01", session: "s-1", model: "claude-sonnet-4-5-20250929",
            at: "2026-10-20T10:00:00.250Z", input: 3, output: 50, cacheWrite: 100, cacheRead: 200)
        let entry = try unwrap(TranscriptLine.parse(Data(line.utf8)))
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
        try expectEqual(try unwrap(TranscriptLine.parse(Data(line.utf8))).tokens,
                        TokenCounts(input: 1, output: 40, cacheWrite: 0, cacheRead: 0))
    }

    static func ignoresNonUsageLines() throws {
        let user = TranscriptFixture.user(session: "s", at: "2026-10-20T10:00:00.000Z")
        let synthetic = TranscriptFixture.assistant(id: "m", session: "s", model: "<synthetic>",
                                                    at: "2026-10-20T10:00:00.000Z")
        try expect(TranscriptLine.parse(Data(user.utf8)) == nil, "用户消息不应读出用量")
        try expect(TranscriptLine.parse(Data(synthetic.utf8)) == nil, "<synthetic> 不应计入")
        try expect(TranscriptLine.parse(Data("{\"type\":\"assistant\",\"mess".utf8)) == nil, "半截行不应读出")
        try expect(TranscriptLine.parse(Data()) == nil, "空行不应读出")
    }

    static func keepsLinesWithoutMessageID() throws {
        let line = TranscriptFixture.assistant(id: nil, session: "s", at: "2026-10-20T10:00:00.000Z", output: 7)
        let entry = try unwrap(TranscriptLine.parse(Data(line.utf8)))
        try expect(entry.messageID == nil, "不应凭空造出 message.id")
        try expectEqual(entry.tokens.output, 7)
    }

    static func parsesTimestampWithoutFraction() throws {
        let line = TranscriptFixture.assistant(id: "m", session: "s", at: "2026-10-20T10:00:00Z")
        try expectEqual(try unwrap(TranscriptLine.parse(Data(line.utf8))).timestamp,
                        Date(timeIntervalSince1970: 1_792_490_400))
    }
}

/// 取出可选值，nil 时检查失败
func unwrap<T>(_ value: T?, _ message: @autoclosure () -> String = "值为 nil",
               file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw CheckFailure(description: "\(file):\(line): \(message())") }
    return value
}
