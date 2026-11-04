// 合成的 Codex 会话记录（~/.codex/sessions/YYYY/MM/DD/rollout-<时间>-<会话 ID>.jsonl 的一行），模仿 spec
// "Further Notes" 记下的真实格式：每行 {timestamp, type, payload}；首行 session_meta；turn_context 带模型；
// event_msg 里的 token_count 带 info.{total,last}_token_usage 与 rate_limits.{primary, secondary}。
// fork 出来的会话记录先写自己的 session_meta（带 forked_from_id），再原样重放父会话的记录（时间戳是重放时的）。
// 检查程序绝不读取真实的 ~/.codex。

import Foundation

enum CodexRollout {
    /// 一份用量（input_tokens 含缓存命中的部分）
    struct Usage {
        var input = 0
        var cached = 0
        var output = 0
        var reasoning = 0
        var cacheWrite: Int?

        var json: [String: Any] {
            var object: [String: Any] = [
                "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                "reasoning_output_tokens": reasoning, "total_tokens": input + output,
            ]
            if let cacheWrite { object["cache_write_input_tokens"] = cacheWrite }
            return object
        }
    }

    /// rate_limits 里的一个窗口
    struct Limit {
        var used: Double
        var minutes: Int
        var resetsAt: Int?
        var resetsInSeconds: Int?

        var json: [String: Any] {
            var object: [String: Any] = ["used_percent": used, "window_minutes": minutes]
            if let resetsAt { object["resets_at"] = resetsAt }
            if let resetsInSeconds { object["resets_in_seconds"] = resetsInSeconds }
            return object
        }
    }

    static func meta(id: String, at timestamp: String, creatorAccountID: String? = "ws-team",
                     creatorUserID: String? = "user-a", originator: String = "codex_cli_rs",
                     forkedFrom: String? = nil) -> String {
        var payload: [String: Any] = [
            "id": id, "timestamp": timestamp, "cwd": "/Users/tester/project", "originator": originator,
            "cli_version": "0.153.4", "source": "cli", "model_provider": "openai",
        ]
        if let creatorAccountID { payload["creator_account_id"] = creatorAccountID }
        if let creatorUserID { payload["creator_user_id"] = creatorUserID }
        if let forkedFrom { payload["forked_from_id"] = forkedFrom }
        return line(timestamp, "session_meta", payload)
    }

    static func turnContext(model: String, at timestamp: String) -> String {
        line(timestamp, "turn_context", [
            "cwd": "/Users/tester/project", "approval_policy": "on-request", "model": model,
            "summary": "auto", "turn_id": UUID().uuidString.lowercased(),
        ])
    }

    static func userMessage(at timestamp: String, text: String = "你好") -> String {
        line(timestamp, "event_msg", ["type": "user_message", "message": text])
    }

    /// 一次 token_count 事件。last 为 nil 时 info 为 null（只带 rate_limits，会话刚开始时会这样）；
    /// primary / secondary 都为 nil 时 rate_limits 为 null
    static func tokenCount(at timestamp: String, last: Usage?, total: Usage? = nil,
                           primary: Limit? = nil, secondary: Limit? = nil,
                           limitID: String? = "codex") -> String {
        var info: Any = NSNull()
        if let last {
            info = ["last_token_usage": last.json, "total_token_usage": (total ?? last).json,
                    "model_context_window": 272_000] as [String: Any]
        }
        var limits: Any = NSNull()
        if primary != nil || secondary != nil {
            var object: [String: Any] = ["primary": primary?.json ?? NSNull(),
                                         "secondary": secondary?.json ?? NSNull(),
                                         "credits": NSNull(), "plan_type": "pro"]
            if let limitID { object["limit_id"] = limitID }
            limits = object
        }
        return line(timestamp, "event_msg", ["type": "token_count", "info": info, "rate_limits": limits])
    }

    /// 会话记录的相对路径（相对主目录）：.codex/<root>/2026/11/04/rollout-2026-11-04T10-00-00-<id>.jsonl
    static func path(_ id: String, root: String = "sessions", day: String = "2026/11/04",
                     compressed: Bool = false) -> String {
        ".codex/\(root)/\(day)/rollout-\(day.replacingOccurrences(of: "/", with: "-"))T10-00-00-\(id).jsonl"
            + (compressed ? ".zst" : "")
    }

    /// 把若干行拼成文件内容（每行以换行结尾）
    static func file(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    private static func line(_ timestamp: String, _ type: String, _ payload: [String: Any]) -> String {
        let object: [String: Any] = ["timestamp": timestamp, "type": type, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// 把内容包成一个只有 Raw 块的 zstd 帧（RFC 8878：魔数、帧头带 4 字节内容大小、不带校验和，
/// 每块最多 128 KB）。只用来在检查里造 .zst 会话记录，不依赖外部的 zstd 程序。
enum RawZstdFrame {
    static func wrap(_ content: Data) -> Data {
        var out = Data([0x28, 0xB5, 0x2F, 0xFD])
        // 帧头描述符：内容大小字段 4 字节（10）、单段（1）、无校验和、无字典
        out.append(0xA0)
        out.append(contentsOf: littleEndian(UInt32(content.count), bytes: 4))
        let blockLimit = 128 << 10
        var start = 0
        repeat {
            let end = min(start + blockLimit, content.count)
            let last: UInt32 = end == content.count ? 1 : 0
            // 块头：最后一块标志、类型 0（Raw）、大小
            out.append(contentsOf: littleEndian(last | UInt32(end - start) << 3, bytes: 3))
            out.append(content[content.startIndex + start ..< content.startIndex + end])
            start = end
        } while start < content.count
        return out
    }

    private static func littleEndian(_ value: UInt32, bytes: Int) -> [UInt8] {
        (0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
