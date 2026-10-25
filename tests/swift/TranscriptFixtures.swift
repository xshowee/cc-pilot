// 合成的 Claude Code 会话记录（~/.claude/projects/<项目>/<会话>.jsonl 的一行），模仿真实格式：
// 每行一个 JSON 对象；assistant 消息按 content block 写成多行，每行重复同一份 message.id 和 usage。
// 检查程序绝不读取真实的 ~/.claude。

import Foundation

enum TranscriptFixture {
    /// 一行 assistant 记录。id 传 nil 时不写 message.id；thinking 非 nil 时在 usage 里附带 thinking_tokens。
    /// advisors 不为空时写 usage.iterations：主模型一轮（数与顶层相同），之后每个 advisor 一轮
    static func assistant(id: String?, session: String, model: String = "claude-opus-5-5",
                          at timestamp: String, input: Int = 0, output: Int = 0,
                          cacheWrite: Int = 0, cacheRead: Int = 0, thinking: Int? = nil,
                          advisors: [(model: String, input: Int, output: Int)] = [],
                          text: String = "好的") -> String {
        var usage: [String: Any] = [
            "input_tokens": input, "output_tokens": output,
            "cache_creation_input_tokens": cacheWrite, "cache_read_input_tokens": cacheRead,
            "service_tier": "standard",
        ]
        if let thinking { usage["thinking_tokens"] = thinking }
        if !advisors.isEmpty {
            func iteration(_ type: String, _ input: Int, _ output: Int, _ cacheWrite: Int,
                           _ cacheRead: Int) -> [String: Any] {
                ["type": type, "input_tokens": input, "output_tokens": output,
                 "cache_creation_input_tokens": cacheWrite, "cache_read_input_tokens": cacheRead]
            }
            usage["iterations"] = [iteration("message", input, output, cacheWrite, cacheRead)]
                + advisors.map { advisor in
                    var it = iteration("advisor_message", advisor.input, advisor.output, 0, 0)
                    it["model"] = advisor.model
                    return it
                }
        }
        var message: [String: Any] = [
            "type": "message", "role": "assistant", "model": model,
            "content": [["type": "text", "text": text]], "usage": usage,
        ]
        if let id { message["id"] = id }
        return line([
            "parentUuid": UUID().uuidString, "isSidechain": false, "userType": "external",
            "cwd": "/Users/tester/project", "sessionId": session, "version": "2.1.0",
            "type": "assistant", "message": message, "requestId": "req_" + (id ?? "none"),
            "uuid": UUID().uuidString, "timestamp": timestamp,
        ])
    }

    /// 一行用户消息（不含 token 用量）
    static func user(session: String, at timestamp: String, text: String = "你好") -> String {
        line([
            "parentUuid": NSNull(), "isSidechain": false, "userType": "external",
            "cwd": "/Users/tester/project", "sessionId": session, "version": "2.1.0",
            "type": "user", "message": ["role": "user", "content": text],
            "uuid": UUID().uuidString, "timestamp": timestamp,
        ])
    }

    /// 把若干行拼成文件内容（每行以换行结尾）
    static func file(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
