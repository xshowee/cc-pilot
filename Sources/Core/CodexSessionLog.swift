// ChatGPT（Codex）会话记录里 cc-pilot 用得到的内容（chatgpt-profiles ticket 08；09 的 Token 账本复用）。
//
// 会话记录 rollout-<时间>-<会话 ID>.jsonl 每行一个 {timestamp, type, payload}（spec "Further Notes"）：
//   session_meta  首行：payload.id（会话 ID）、creator_account_id（工作区 ID）、creator_user_id、originator、
//                 fork / 子代理出来的会话另有 forked_from_id 或 source.subagent.thread_spawn.parent_thread_id
//   turn_context  每轮开始：payload.model（之后的 token_count 属于这个模型）
//   event_msg     payload.type == token_count：info.{last,total}_token_usage（info 可能为 null）、
//                 rate_limits.{primary, secondary}（used_percent、window_minutes、resets_at）
// 其他行不看（先按字节预筛，再 JSON 解析：会话记录里大行很多）。
//
// fork（以及带父会话历史的子代理）出来的会话记录：先写自己的 session_meta，再把父会话的记录重放一遍
// （包括父会话的 session_meta 与 token_count，时间戳是重放时的），之后才是自己的事件。父会话本身是 fork 出来的时，
// 重放里还套着祖父会话的 session_meta 与事件（父会话文件的原样）。
// 去重键不用时间戳，而用"范围 + 累计用量 + 本次用量"，范围 = 事件原本所属的会话：
//   - 读到 session_meta：范围切到它的 id（自己的会话 ID，或重放开始的父 / 祖父会话 ID），记进这份文件的会话链。
//   - 读到 turn_context：回合 ID 与会话 ID 都是 UUIDv7（前 48 位是创建时刻）时，回合属于会话链里"在回合开始时
//     已经存在的最新的那个会话"——范围切到它。fork 自己的回合晚于自己的会话 ID，于是重放到此结束，范围回到自己；
//     重放里父会话自己的回合早于 fork、晚于父会话的创建，范围回到父会话（嵌套的重放）。
//     看不出时刻（老版本的回合 ID 是 UUIDv4、或没有回合 ID）时范围不变：之后的事件仍算在重放的会话名下，
//     与父会话之后的事件累计用量相同才会合并（之前的做法）。
//   这样重放的事件与父会话自己文件里的同一事件处在同一个范围（同一会话），累计用量相同 → 去重键相同；
//   fork / 子代理自己的事件在自己的范围里，不会与父会话、兄弟会话用量恰好相同的事件合并。
//   累计用量（total_token_usage）在一个会话里只增不减，同一范围里不同的事件累计用量不同；
//   同一个事件写了两遍（只更新 rate_limits 时会重发相同的 info）去重键也相同。
// 范围不是自己的会话 ID 的事件标为重放（replayed）：它们是父会话的旧事件，rate_limits 不是新鲜的实时额度。
// 没有 total_token_usage 的事件退回用时间戳。重放的事件在新文件里的会话 ID 是新会话的（写这份文件的会话），
// 先读到哪份就按哪份记（文件按路径排序读，父会话的文件更早）。
// 待真机验证（ticket 13）：fork 重放父会话的 session_meta；会话 ID、回合 ID 是 UUIDv7；嵌套 fork 的重放形状。

import Foundation

/// 会话记录首行 session_meta 里有用的部分
struct CodexSessionMeta: Equatable, Codable {
    /// 会话 ID（payload.id）
    let id: String
    /// 工作区 ID：同一 Team 工作区的不同用户相同，不能用来区分账号
    var creatorAccountID: String?
    /// 创建会话的用户（chatgpt_user_id）：只用于校验归属
    var creatorUserID: String?
    /// 写会话的客户端，例如 codex_cli_rs、codex_vscode、桌面 App
    var originator: String?
    /// fork 出来的会话：被 fork 的会话 ID
    var forkedFromID: String?
    /// 子代理会话：父线程 ID
    var parentThreadID: String?

    init(id: String, creatorAccountID: String? = nil, creatorUserID: String? = nil, originator: String? = nil,
         forkedFromID: String? = nil, parentThreadID: String? = nil) {
        self.id = id
        self.creatorAccountID = creatorAccountID
        self.creatorUserID = creatorUserID
        self.originator = originator
        self.forkedFromID = forkedFromID
        self.parentThreadID = parentThreadID
    }

}

/// token_count 的 last_token_usage，原样保存（四类映射由账本做：输入 = input − cachedInput 等，spec）
struct CodexTokenUsage: Equatable {
    /// input_tokens：含缓存命中的部分
    var input: Int
    /// cached_input_tokens
    var cachedInput: Int
    /// cache_write_input_tokens（旧版本没有，为 0）
    var cacheWriteInput: Int
    /// output_tokens：含推理
    var output: Int
    /// reasoning_output_tokens
    var reasoningOutput: Int
    /// total_tokens
    var total: Int
}

/// token_count 的 rate_limits：按 window_minutes 识别出的两个窗口（不按 primary / secondary 的位置猜）
struct CodexRateLimits: Equatable {
    static let fiveHourMinutes = 300
    static let weekMinutes = 10_080

    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
}

/// 一次 token_count 事件
struct CodexTokenCountEvent: Equatable {
    /// 写这份会话记录的会话（文件自己的 session_meta；还没读到时取文件名里的 ID）
    let sessionID: String
    /// 行的 timestamp（重放的事件是重放时间）
    let timestamp: Date
    /// 之前最近一次 turn_context 的模型；还没有时为 nil
    let model: String?
    /// info.last_token_usage；info 为 null（只带 rate_limits）时为 nil
    let usage: CodexTokenUsage?
    /// rate_limits；为 null、或两个窗口都认不出时为 nil
    let rateLimits: CodexRateLimits?
    /// 跨文件去重键（见文件头）：resume、fork 重放的同一事件相同
    let deduplicationKey: String
    /// fork / 带历史的子代理把父会话的记录重放进这份文件时的事件（不是这个会话自己的，见文件头）
    var replayed = false
}

/// 一份会话记录读到哪里，以及接着读下去需要的上下文。下次扫描原样传回；可编码，09 可存进账本
struct CodexFileCursor: Equatable, Codable {
    /// .jsonl：已读完的字节数；.zst：上次整份读取时的文件大小
    var offset: Int
    var inode: Int
    /// .zst：上次整份读取时的修改时间（秒）；.jsonl 不用
    var modified: Double?
    /// 文件自己的会话 ID（首行 session_meta）
    var sessionID: String?
    /// 当前的去重范围：接下来的事件原本所属的会话（见文件头）
    var scope: String?
    /// 这份文件里出现过的 session_meta 的 id，按出现顺序（第一个是文件自己的会话）
    var lineage: [String]?
    /// 当前的模型（最近一次 turn_context）
    var model: String?
}

/// 解析会话记录的行，维护文件级上下文（会话 ID、去重范围、模型）
struct CodexSessionLogParser {
    private(set) var cursor: CodexFileCursor
    private let fallbackSessionID: String
    private(set) var meta: CodexSessionMeta?
    private(set) var events: [CodexTokenCountEvent] = []

    init(cursor: CodexFileCursor, fileName: String) {
        self.cursor = cursor
        fallbackSessionID = Self.sessionID(fromFileName: fileName) ?? fileName
    }

    mutating func parse(_ line: Data) {
        guard Self.markers.contains(where: { line.range(of: $0) != nil }),
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        switch object["type"] as? String {
        case "session_meta":
            guard let id = Self.nonEmpty(payload["id"]) else { return }
            let source = payload["source"] as? [String: Any]
            let spawn = ((source?["subagent"] as? [String: Any])?["thread_spawn"]) as? [String: Any]
            let parsed = CodexSessionMeta(
                id: id, creatorAccountID: Self.nonEmpty(payload["creator_account_id"]),
                creatorUserID: Self.nonEmpty(payload["creator_user_id"]),
                originator: Self.nonEmpty(payload["originator"]),
                forkedFromID: Self.nonEmpty(payload["forked_from_id"]),
                parentThreadID: Self.nonEmpty(payload["parent_thread_id"]) ?? Self.nonEmpty(spawn?["parent_thread_id"]))
            if cursor.sessionID == nil {
                cursor.sessionID = id
                meta = parsed
            }
            var lineage = cursor.lineage ?? []
            if !lineage.contains(id) { lineage.append(id) }
            cursor.lineage = lineage
            cursor.scope = id
        case "turn_context":
            if let model = Self.nonEmpty(payload["model"]) { cursor.model = model }
            if let turn = Self.nonEmpty(payload["turn_id"]), let owner = owner(ofTurn: turn) { cursor.scope = owner }
        case "event_msg":
            guard payload["type"] as? String == "token_count",
                  let text = object["timestamp"] as? String, let timestamp = TranscriptLine.parseTimestamp(text)
            else { return }
            let info = payload["info"] as? [String: Any]
            let last = (info?["last_token_usage"] as? [String: Any]).map(Self.usage)
            let total = (info?["total_token_usage"] as? [String: Any]).map(Self.usage)
            let limits = Self.rateLimits(payload["rate_limits"], at: timestamp)
            guard last != nil || limits != nil else { return }
            let sessionID = cursor.sessionID ?? fallbackSessionID
            let scope = cursor.scope ?? sessionID
            events.append(CodexTokenCountEvent(
                sessionID: sessionID, timestamp: timestamp, model: cursor.model, usage: last, rateLimits: limits,
                deduplicationKey: Self.key(scope: scope, total: total, last: last, timestamp: text),
                replayed: scope != sessionID))
        default:
            return
        }
    }

    /// 回合所属的会话：会话链里创建时刻不晚于回合开始时刻的最新的那个（都按 UUIDv7 的时刻）；看不出时为 nil
    private func owner(ofTurn turn: String) -> String? {
        guard let started = Self.uuidV7Time(turn), let lineage = cursor.lineage else { return nil }
        var best: (id: String, created: UInt64)?
        for id in lineage {
            guard let created = Self.uuidV7Time(id), created <= started else { continue }
            if best == nil || created > best!.created { best = (id, created) }
        }
        return best?.id
    }

    /// UUIDv7 的创建时刻（前 48 位，Unix 毫秒）；不是 UUIDv7 时为 nil
    static func uuidV7Time(_ id: String) -> UInt64? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let b = uuid.uuid
        guard b.6 >> 4 == 7 else { return nil }
        return [b.0, b.1, b.2, b.3, b.4, b.5].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// rollout-2026-11-04T10-00-00-<UUID>.jsonl[.zst] 里的会话 ID（最后 36 个字符）
    static func sessionID(fromFileName name: String) -> String? {
        var base = Substring(name)
        for suffix in [".zst", ".jsonl"] where base.hasSuffix(suffix) { base = base.dropLast(suffix.count) }
        guard base.count > 36 else { return nil }
        let id = base.suffix(36)
        return UUID(uuidString: String(id)) != nil ? String(id) : nil
    }

    private static let markers = [#""session_meta""#, #""turn_context""#, #""token_count""#].map { Data($0.utf8) }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func count(_ object: [String: Any], _ key: String) -> Int {
        UsageSnapshot.number(object[key]).map { Int($0) } ?? 0
    }

    private static func usage(_ object: [String: Any]) -> CodexTokenUsage {
        CodexTokenUsage(input: count(object, "input_tokens"), cachedInput: count(object, "cached_input_tokens"),
                        cacheWriteInput: count(object, "cache_write_input_tokens"),
                        output: count(object, "output_tokens"),
                        reasoningOutput: count(object, "reasoning_output_tokens"),
                        total: count(object, "total_tokens"))
    }

    /// rate_limits：limit_id 不是 codex 的（按模型另计的额度）不算；窗口按 window_minutes 识别。
    /// resets_at 缺失时用旧版本的 resets_in_seconds（相对事件时间）
    private static func rateLimits(_ value: Any?, at timestamp: Date) -> CodexRateLimits? {
        guard let object = value as? [String: Any] else { return nil }
        if let id = object["limit_id"] as? String, id != "codex" { return nil }
        var limits = CodexRateLimits()
        for key in ["primary", "secondary"] {
            guard let window = object[key] as? [String: Any],
                  let used = UsageSnapshot.number(window["used_percent"]),
                  let minutes = UsageSnapshot.number(window["window_minutes"]) else { continue }
            var resetsAt = UsageSnapshot.date(window["resets_at"])
            if resetsAt == nil, let seconds = UsageSnapshot.number(window["resets_in_seconds"]) {
                resetsAt = timestamp.addingTimeInterval(seconds)
            }
            let parsed = UsageWindow(utilization: used, resetsAt: resetsAt)
            switch Int(minutes) {
            case CodexRateLimits.fiveHourMinutes where limits.fiveHour == nil: limits.fiveHour = parsed
            case CodexRateLimits.weekMinutes where limits.sevenDay == nil: limits.sevenDay = parsed
            default: continue
            }
        }
        return limits.fiveHour == nil && limits.sevenDay == nil ? nil : limits
    }

    private static func key(scope: String, total: CodexTokenUsage?, last: CodexTokenUsage?, timestamp: String) -> String {
        func fields(_ u: CodexTokenUsage?) -> String {
            guard let u else { return "-" }
            return [u.input, u.cachedInput, u.cacheWriteInput, u.output, u.reasoningOutput, u.total]
                .map(String.init).joined(separator: ",")
        }
        // 只有 rate_limits 的事件没有用量，账本不记它，键只要求稳定
        if total == nil { return "codex:\(scope):\(timestamp):\(fields(last))" }
        return "codex:\(scope):\(fields(total)):\(fields(last))"
    }
}
