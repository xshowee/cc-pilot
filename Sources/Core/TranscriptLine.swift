// Claude Code 会话记录（~/.claude/projects/<项目>/<会话>.jsonl，含 <会话>/subagents/*.jsonl）的一行。
// Token 用量的唯一数据来源（spec 决策 6）。只关心 assistant 消息里的 message.usage：
//
//   {"type":"assistant","sessionId":"…","timestamp":"2026-10-20T10:00:00.123Z",
//    "message":{"id":"msg_…","model":"claude-opus-5-5","usage":{"input_tokens":…,"output_tokens":…,
//      "cache_creation_input_tokens":…,"cache_read_input_tokens":…}}}
//
// 同一条消息按 content block 写成多行、每行重复同一份 usage，去重由账本按 message.id 做，这里不管。
// thinking_tokens 是 output_tokens 的子集，不另加。模型是 <synthetic> 的条目（Claude Code 自己合成的
// 消息，没有真的调用模型）不计。

import Foundation

/// 四类 token 数。合计 = 输入 + 输出 + 缓存写入 + 缓存读取（spec 决策 5）。
struct TokenCounts: Equatable, Sendable {
    var input: Int
    var output: Int
    /// cache_creation_input_tokens
    var cacheWrite: Int
    /// cache_read_input_tokens
    var cacheRead: Int

    static let zero = TokenCounts(input: 0, output: 0, cacheWrite: 0, cacheRead: 0)

    var total: Int { input + output + cacheWrite + cacheRead }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output,
                    cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

/// 一行会话记录里读出的一条 assistant 消息的用量
struct TranscriptLine: Equatable, Sendable {
    /// message.id；个别行没有，这样的行照常计入、不参与去重
    let messageID: String?
    let timestamp: Date
    /// 行里的 sessionId（子代理会话记录里也是这个字段）
    let sessionID: String
    /// 原始模型 ID，例如 claude-opus-5-5；显示名见 ModelDisplayName
    let model: String
    let tokens: TokenCounts

    /// 不是带用量的 assistant 消息（用户消息、摘要、半截行、<synthetic> 等）时返回 nil
    static func parse(_ line: Data) -> TranscriptLine? {
        guard !line.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model != syntheticModel,
              let sessionID = object["sessionId"] as? String,
              let stamp = object["timestamp"] as? String, let timestamp = parseTimestamp(stamp)
        else { return nil }
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return TranscriptLine(
            messageID: message["id"] as? String, timestamp: timestamp, sessionID: sessionID, model: model,
            tokens: TokenCounts(input: count("input_tokens"), output: count("output_tokens"),
                                cacheWrite: count("cache_creation_input_tokens"),
                                cacheRead: count("cache_read_input_tokens")))
    }

    static let syntheticModel = "<synthetic>"

    /// ISO 8601，带或不带毫秒
    static func parseTimestamp(_ text: String) -> Date? {
        fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text)
    }

    // 首次回填要解析几十万行，格式化器只建一次（ISO8601DateFormatter 可在线程之间共用）
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let plainFormatter = ISO8601DateFormatter()
}
