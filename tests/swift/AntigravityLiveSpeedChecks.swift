// Antigravity 当前在线账号实时生成速度检查（antigravity-usage ticket 05）。
// 覆盖接缝：
//   1. AntigravityModelResolver.extractSteps  显式结束时间（不回退 createdAt / summaryLastModifiedAt）、0-input >=50 输出、纳秒耗时
//   2. AntigravityLiveSpeed.compute            根+子代理合并、严格 5 项过滤、多账号/离线隔离、排序与均值
//   3. TokenUsageRecorder                      FSEvents 增量缓存合并（只改单条轨迹时仍保留同组另一条）、离线/登出/停用即清空 nil

import Foundation

final class AntigravityLiveSpeedChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("步骤解析：保留显式结束时间（不回退 createdAt / summary）、解析 0-input 且 output>=50 步骤与纳秒精度耗时", stepTimestampAndZeroInputParsing),
            Check("速度计算与过滤：根+子代理合并、严格 5 项过滤剔除无效步（含 TTFT 越界与 CHECKPOINT）、缺 TTFT 仍计入速度", speedCalculationAndStrictFiltering),
            Check("多账号与离线安全：排除他号已绑定会话与启动前 30s 离线会话，按最新根会话（含子代理更新时间）挑选", multiAccountAndOfflineScoping),
            Check("端到端 FSEvents 监听与清空：只改单条轨迹时缓存合并另一条；无持久化污染(v5)；离线、切号无样本及停用即刻发 nil", endToEndRecorderCachingAndClearing),
            Check("空闲重校验与 App 退出清空：liveSpeed 为 nil 时零请求；空闲登出/切号/离线重校验发 nil；App 退出零请求清空且保留监听水位线", idleRevalidationAndAppTermination),
        ]
    }

    static func stepTimestampAndZeroInputParsing() throws {
        let userStatusData = Data(#"{"userStatus":{"email":"speed@example.com"}}"#.utf8)
        let status = AntigravityModelResolver.parseUserStatus(userStatusData)
        let summaryFallback = Date(timeIntervalSince1970: 1_794_750_000)

        let data = Data(#"""
        {
          "trajectory": {
            "numTotalSteps": 5,
            "steps": [
              {
                "status": "CORTEX_STEP_STATUS_DONE",
                "metadata": {
                  "sourceTrajectoryStepInfo": { "stepIndex": 0 },
                  "createdAt": "2026-11-15T10:00:00.100Z",
                  "finishedGeneratingAt": "2026-11-15T10:00:00.600Z",
                  "generatorMetadata": [
                    { "chatModel": { "timeToFirstToken": "0.25s" } }
                  ],
                  "modelUsage": {
                    "model": "MODEL_PLACEHOLDER_M18",
                    "inputTokens": "0",
                    "outputTokens": "50",
                    "cacheReadTokens": "0"
                  }
                }
              },
              {
                "status": "CORTEX_STEP_STATUS_DONE",
                "metadata": {
                  "sourceTrajectoryStepInfo": { "stepIndex": 1 },
                  "createdAt": "2026-11-15T10:01:00Z",
                  "completedAt": "2026-11-15T10:01:02Z",
                  "modelUsage": {
                    "model": "MODEL_PLACEHOLDER_M18",
                    "inputTokens": "10",
                    "outputTokens": "60"
                  }
                }
              },
              {
                "status": "CORTEX_STEP_STATUS_DONE",
                "metadata": {
                  "sourceTrajectoryStepInfo": { "stepIndex": 2 },
                  "createdAt": "2026-11-15T10:02:00Z",
                  "modelUsage": {
                    "model": "MODEL_PLACEHOLDER_M18",
                    "inputTokens": "10",
                    "outputTokens": "80"
                  }
                }
              },
              {
                "status": "CORTEX_STEP_STATUS_DONE",
                "metadata": {
                  "sourceTrajectoryStepInfo": { "stepIndex": 3 },
                  "modelUsage": {
                    "model": "MODEL_PLACEHOLDER_M18",
                    "inputTokens": "10",
                    "outputTokens": "90"
                  }
                }
              },
              {
                "status": "CORTEX_STEP_STATUS_DONE",
                "metadata": {
                  "sourceTrajectoryStepInfo": { "stepIndex": 4 },
                  "createdAt": "2026-11-15T10:03:00.000000000Z",
                  "finishedGeneratingAt": "2026-11-15T10:03:00.499999999Z",
                  "modelUsage": {
                    "model": "MODEL_PLACEHOLDER_M18",
                    "inputTokens": "10",
                    "outputTokens": "100"
                  }
                }
              }
            ]
          }
        }
        """#.utf8)

        let extracted = AntigravityModelResolver.extractSteps(
            cascadeID: "Root-Speed",
            trajectoryData: data,
            summaryLastModifiedAt: summaryFallback,
            summaryParentID: nil,
            summaryRootID: nil,
            dynamicModels: status.dynamicModels)

        guard case .complete(let batch) = extracted else {
            throw CheckFailure(description: "完整轨迹不应判为截断")
        }
        try expectEqual(batch.steps.count, 5)

        // Step 0: 0 input, 50 output, exact 0.500s, finishedGeneratingAt preserved, ttft 0.25s
        let s0 = batch.steps[0]
        try expectEqual(s0.tokens, TokenCounts(input: 0, output: 50, cacheWrite: 0, cacheRead: 0))
        try expectEqual(s0.timeToFirstTokenSec, 0.25)
        try expect(s0.explicitEndAt != nil, "finishedGeneratingAt 应保留为 explicitEndAt")
        let s0Dur = try unwrap(s0.explicitDurationSec)
        try expect(s0Dur >= 0.5, "0.100Z 到 0.600Z 精确耗时应 >= 0.5s，实际 \(s0Dur)")

        // Step 1: only completedAt -> explicitEndAt preserved without finishedGeneratingAt
        let s1 = batch.steps[1]
        let expectedEnd1 = try unwrap(AntigravityModelResolver.parseISO8601("2026-11-15T10:01:02Z"))
        try expectEqual(s1.finishedAt, nil)
        try expect(abs((try unwrap(s1.explicitEndAt)).timeIntervalSince(expectedEnd1)) < 1e-6, "completedAt 应精确保留")

        // Step 2: only createdAt -> explicitEndAt must be nil (no fallback to createdAt)
        let s2 = batch.steps[2]
        try expectEqual(s2.explicitEndAt, nil, "仅 createdAt 时 explicitEndAt 不得回退为 createdAt")

        // Step 3: no step timestamps -> completedAt falls back to summary, explicitEndAt must be nil
        let s3 = batch.steps[3]
        try expect(abs(s3.completedAt.timeIntervalSince(summaryFallback)) < 1e-6, "summary 回退时间")
        try expectEqual(s3.explicitEndAt, nil, "回退 summaryLastModifiedAt 时 explicitEndAt 必须为 nil")

        // Step 4: 499,999,999 ns must stay < 0.5s
        let s4 = batch.steps[4]
        let s4Dur = try unwrap(s4.explicitDurationSec)
        try expect(s4Dur < 0.5, "499,999,999ns 耗时必须严格小于 0.5s，实际 \(s4Dur)")
    }

    private static func makeStep(
        session: String,
        idx: Int,
        start: Date?,
        end: Date?,
        output: Int,
        ttft: Double? = nil,
        isCompaction: Bool = false,
        isDone: Bool = true
    ) -> AntigravityTrajectoryStep {
        AntigravityTrajectoryStep(
            messageID: "antigravity:\(session.lowercased()):\(idx)",
            sessionID: session.lowercased(),
            stepIndex: idx,
            completedAt: end ?? start ?? Date(timeIntervalSince1970: 1_794_750_000),
            createdAt: start,
            finishedAt: end,
            explicitEndAt: end,
            isDone: isDone,
            model: "gemini-4-carbon-high",
            tokens: TokenCounts(input: 10, output: output, cacheWrite: 0, cacheRead: 0),
            isCompactionStep: isCompaction,
            timeToFirstTokenSec: ttft)
    }

    static func speedCalculationAndStrictFiltering() throws {
        let base = Date(timeIntervalSince1970: 1_794_750_000)

        // Root steps:
        // - r0: valid (t+0..t+2, dur=2s, out=100, ttft=0.5s) -> 50 tok/s
        // - r1: invalid short duration (0.49s, out=200) -> rejected
        // - r2: invalid low output (dur=2s, out=49) -> rejected
        // - r3: invalid TTFT > duration + 0.01 (dur=2s, out=300, ttft=2.02s) -> rejected from BOTH latest and avg!
        // - r4: invalid negative TTFT (dur=2s, out=300, ttft=-0.1s) -> rejected
        // - r5: invalid CHECKPOINT (dur=2s, out=400, ttft=0.2s) -> rejected
        // - r6: invalid non-DONE (dur=2s, out=400) -> rejected
        // - r7: invalid missing explicit endAt -> rejected
        let rootSteps = [
            makeStep(session: "root-1", idx: 0, start: base, end: base.addingTimeInterval(2), output: 100, ttft: 0.5),
            makeStep(session: "root-1", idx: 1, start: base.addingTimeInterval(3), end: base.addingTimeInterval(3.49), output: 200, ttft: 0.1),
            makeStep(session: "root-1", idx: 2, start: base.addingTimeInterval(4), end: base.addingTimeInterval(6), output: 49, ttft: 0.2),
            makeStep(session: "root-1", idx: 3, start: base.addingTimeInterval(7), end: base.addingTimeInterval(9), output: 300, ttft: 2.02),
            makeStep(session: "root-1", idx: 4, start: base.addingTimeInterval(10), end: base.addingTimeInterval(12), output: 300, ttft: -0.1),
            makeStep(session: "root-1", idx: 5, start: base.addingTimeInterval(13), end: base.addingTimeInterval(15), output: 400, ttft: 0.2, isCompaction: true),
            makeStep(session: "root-1", idx: 6, start: base.addingTimeInterval(16), end: base.addingTimeInterval(18), output: 400, isDone: false),
            makeStep(session: "root-1", idx: 7, start: base.addingTimeInterval(19), end: nil, output: 400),
        ]

        // Subagent steps:
        // - s0: valid (t+20..t+24, dur=4s, out=200, ttft=nil) -> 50 tok/s, ttft=nil allowed!
        // - s1: valid boundary ttft = dur + 0.01 (t+1..t+3, dur=2s, out=80, ttft=2.01s) -> allowed!
        let subSteps = [
            makeStep(session: "sub-1", idx: 0, start: base.addingTimeInterval(20), end: base.addingTimeInterval(24), output: 200, ttft: nil),
            makeStep(session: "sub-1", idx: 1, start: base.addingTimeInterval(1), end: base.addingTimeInterval(3), output: 80, ttft: 2.01),
        ]

        let rootBatch = AntigravityExtractedBatch(
            sessionID: "root-1", parentSessionID: nil, rootSessionID: "root-1",
            childCascadeIDs: ["sub-1"], steps: rootSteps)
        let subBatch = AntigravityExtractedBatch(
            sessionID: "sub-1", parentSessionID: "root-1", rootSessionID: "root-1",
            childCascadeIDs: [], steps: subSteps)

        let speed = try unwrap(AntigravityLiveSpeed.compute(
            onlineEmail: "UserA@Example.com",
            listenerStartedAt: base.addingTimeInterval(-10),
            cascades: [
                AntigravityCascadeSnapshot(batch: rootBatch, lastModifiedAt: base.addingTimeInterval(19), resolvedRootID: "root-1"),
                AntigravityCascadeSnapshot(batch: subBatch, lastModifiedAt: base.addingTimeInterval(24), resolvedRootID: "root-1"),
            ]))

        // Valid steps sorted chronologically: r0 (t+2, out=100, dur=2), s1 (t+3, out=80, dur=2), s0 (t+24, out=200, dur=4)
        // Latest = s0 -> latestTokPerSec = 200 / 4 = 50.0, latestTtftSec = nil
        // Session avg = (100 + 80 + 200) / (2 + 2 + 4) = 380 / 8 = 47.5
        try expectEqual(speed.email, "usera@example.com")
        try expect(abs(speed.latestTokPerSec - 50.0) < 1e-9, "最新有效步应为子代理 s0 (50.0 tok/s)")
        try expectEqual(speed.latestTtftSec, nil, "最新有效步缺 TTFT 时应返回 nil 而非沿用旧步 TTFT")
        try expect(abs(speed.sessionAvgTokPerSec - 47.5) < 1e-9, "会话平均应合并根+子代理并剔除无效步 (47.5 tok/s)")

        // Latest step WITH TTFT
        let withTtft = AntigravityExtractedBatch(
            sessionID: "sub-2", parentSessionID: "root-1", rootSessionID: "root-1",
            childCascadeIDs: [],
            steps: [makeStep(session: "sub-2", idx: 0, start: base.addingTimeInterval(25), end: base.addingTimeInterval(27), output: 120, ttft: 0.8)])
        let speedWithTtft = try unwrap(AntigravityLiveSpeed.compute(
            onlineEmail: "UserA@Example.com",
            listenerStartedAt: base.addingTimeInterval(-10),
            cascades: [
                AntigravityCascadeSnapshot(batch: rootBatch, lastModifiedAt: base.addingTimeInterval(19), resolvedRootID: "root-1"),
                AntigravityCascadeSnapshot(batch: subBatch, lastModifiedAt: base.addingTimeInterval(24), resolvedRootID: "root-1"),
                AntigravityCascadeSnapshot(batch: withTtft, lastModifiedAt: base.addingTimeInterval(27), resolvedRootID: "root-1"),
            ]))
        try expect(abs(speedWithTtft.latestTokPerSec - 60.0) < 1e-9, "携带 TTFT 的最新步应为 60.0 tok/s")
        try expectEqual(speedWithTtft.latestTtftSec, 0.8)
        // (380 + 120) / (8 + 2) = 50.0
        try expect(abs(speedWithTtft.sessionAvgTokPerSec - 50.0) < 1e-9, "合入 sub-2 后会话均值应为 50.0 tok/s")

        // Zero valid steps -> nil
        let invalidOnly = AntigravityExtractedBatch(
            sessionID: "root-invalid", parentSessionID: nil, rootSessionID: "root-invalid",
            childCascadeIDs: [],
            steps: [makeStep(session: "root-invalid", idx: 0, start: base, end: base.addingTimeInterval(0.3), output: 100, ttft: 0.1)])
        try expectEqual(AntigravityLiveSpeed.compute(
            onlineEmail: "usera@example.com",
            listenerStartedAt: base.addingTimeInterval(-10),
            cascades: [AntigravityCascadeSnapshot(batch: invalidOnly, lastModifiedAt: base, resolvedRootID: "root-invalid")]),
            nil, "无有效样本时必须返回 nil")
    }

    static func multiAccountAndOfflineScoping() throws {
        let startedAt = Date(timeIntervalSince1970: 1_794_750_000)

        // 1) Old unbound offline conversation (< startedAt - 30s) must be excluded
        let oldOffline = AntigravityCascadeSnapshot(
            batch: AntigravityExtractedBatch(
                sessionID: "old-offline", parentSessionID: nil, rootSessionID: "old-offline",
                childCascadeIDs: [],
                steps: [makeStep(session: "old-offline", idx: 0, start: startedAt.addingTimeInterval(-40), end: startedAt.addingTimeInterval(-31), output: 200, ttft: 0.4)]),
            lastModifiedAt: startedAt.addingTimeInterval(500),
            resolvedRootID: "old-offline")

        // 2) Conversation bound to UserB (must be excluded when UserA is online)
        let userBConv = AntigravityCascadeSnapshot(
            batch: AntigravityExtractedBatch(
                sessionID: "conv-b", parentSessionID: nil, rootSessionID: "conv-b",
                childCascadeIDs: [],
                steps: [makeStep(session: "conv-b", idx: 0, start: startedAt.addingTimeInterval(100), end: startedAt.addingTimeInterval(102), output: 400, ttft: 0.3)]),
            lastModifiedAt: startedAt.addingTimeInterval(102),
            resolvedRootID: "conv-b")

        // 3) Older UserA root whose subagent was modified more recently (t+80s) than UserA's other root (t+60s)
        let userARoot1 = AntigravityCascadeSnapshot(
            batch: AntigravityExtractedBatch(
                sessionID: "conv-a1", parentSessionID: nil, rootSessionID: "conv-a1",
                childCascadeIDs: ["sub-a1"],
                steps: [makeStep(session: "conv-a1", idx: 0, start: startedAt.addingTimeInterval(10), end: startedAt.addingTimeInterval(12), output: 100, ttft: 0.5)]),
            lastModifiedAt: startedAt.addingTimeInterval(12),
            resolvedRootID: "conv-a1")
        let userASub1 = AntigravityCascadeSnapshot(
            batch: AntigravityExtractedBatch(
                sessionID: "sub-a1", parentSessionID: "conv-a1", rootSessionID: "conv-a1",
                childCascadeIDs: [],
                steps: [makeStep(session: "sub-a1", idx: 0, start: startedAt.addingTimeInterval(78), end: startedAt.addingTimeInterval(80), output: 160, ttft: 0.4)]),
            lastModifiedAt: startedAt.addingTimeInterval(80),
            resolvedRootID: "conv-a1")
        let userARoot2 = AntigravityCascadeSnapshot(
            batch: AntigravityExtractedBatch(
                sessionID: "conv-a2", parentSessionID: nil, rootSessionID: "conv-a2",
                childCascadeIDs: [],
                steps: [makeStep(session: "conv-a2", idx: 0, start: startedAt.addingTimeInterval(58), end: startedAt.addingTimeInterval(60), output: 300, ttft: 0.2)]),
            lastModifiedAt: startedAt.addingTimeInterval(60),
            resolvedRootID: "conv-a2")

        let boundAccounts = [
            "conv-b": "antigravity:userb@example.com",
            "conv-a1": "antigravity:usera@example.com",
            "conv-a2": "antigravity:usera@example.com",
        ]

        // Offline (onlineEmail == nil) -> nil
        try expectEqual(AntigravityLiveSpeed.compute(
            onlineEmail: nil, listenerStartedAt: startedAt,
            cascades: [oldOffline, userBConv, userARoot1, userASub1, userARoot2],
            boundAccounts: boundAccounts), nil)

        // Only oldOffline + userBConv when UserA is online -> nil
        try expectEqual(AntigravityLiveSpeed.compute(
            onlineEmail: "UserA@Example.com", listenerStartedAt: startedAt,
            cascades: [oldOffline, userBConv],
            boundAccounts: boundAccounts), nil)

        // UserA online with all cascades -> picks conv-a1 (groupLastModifiedAt = t+80 > t+60), ignoring conv-b & old-offline
        let speedA = try unwrap(AntigravityLiveSpeed.compute(
            onlineEmail: "UserA@Example.com", listenerStartedAt: startedAt,
            cascades: [oldOffline, userBConv, userARoot1, userASub1, userARoot2],
            boundAccounts: boundAccounts))
        try expectEqual(speedA.email, "usera@example.com")
        try expect(abs(speedA.latestTokPerSec - 80.0) < 1e-9, "应选中包含最新子代理的 conv-a1 组（latest=160/2=80）")
        try expectEqual(speedA.latestTtftSec, 0.4)
        // (100 + 160) / (2 + 2) = 65.0
        try expect(abs(speedA.sessionAvgTokPerSec - 65.0) < 1e-9, "conv-a1 组均值应为 65.0 tok/s")
    }

    // MARK: - End-to-End FSEvents Slice 4

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value
        init(_ value: Value) { storage = value }
        var value: Value {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    private final class ScriptedTransport: UsageTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        let handler: @Sendable (URLRequest) throws -> UsageHTTPResponse

        init(_ handler: @escaping @Sendable (URLRequest) throws -> UsageHTTPResponse) {
            self.handler = handler
        }

        var requests: [URLRequest] { lock.withLock { _requests } }

        func fetchedCascadeIDs() -> [String] {
            requests
                .filter { $0.url?.path.hasSuffix("/GetCascadeTrajectory") == true }
                .compactMap { req in
                    (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])?["cascadeId"] as? String
                }
        }

        func send(_ request: URLRequest) throws -> UsageHTTPResponse {
            lock.withLock { _requests.append(request) }
            return try handler(request)
        }
    }

    private static func jsonResponse(_ body: String, status: Int = 200) -> UsageHTTPResponse {
        UsageHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    private static func waitUntil(_ timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return predicate()
    }

    static func endToEndRecorderCachingAndClearing() throws {
        let home = try TempHome()
        defer { home.remove() }
        let convDir = home.url.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
        let procs = home.antigravityProcesses
        procs.run(pid: 8801, startedAt: 100, token: "tok-speed", ports: [45001])

        let lsPrefix = "/exa.language_server_pb.LanguageServerService/"
        let phase = LockedBox(1)
        let currentEmail = LockedBox<String?>("UserA@Example.com")
        let serverOffline = LockedBox(false)

        let transport = ScriptedTransport { req in
            if serverOffline.value {
                return jsonResponse("{}", status: 503)
            }
            let p = phase.value
            let email = currentEmail.value
            switch req.url?.path {
            case lsPrefix + "GetUserStatus":
                if let email {
                    return jsonResponse(#"{"userStatus":{"email":"\#(email)"}}"#)
                }
                return jsonResponse(#"{"userStatus":{}}"#)
            case lsPrefix + "GetAllCascadeTrajectories":
                if p == 1 {
                    return jsonResponse(#"""
                    {
                      "trajectorySummaries": {
                        "Old-Offline": { "stepCount": 1, "lastModifiedTime": "2026-11-15T12:00:00Z" },
                        "Root-1": { "stepCount": 1, "lastModifiedTime": "2026-11-15T12:00:05Z" },
                        "Sub-1": { "stepCount": 1, "lastModifiedTime": "2026-11-15T12:00:10Z", "trajectoryMetadata": { "rootConversationId": "Root-1" } }
                      }
                    }
                    """#)
                }
                return jsonResponse(#"""
                {
                  "trajectorySummaries": {
                    "Old-Offline": { "stepCount": 1, "lastModifiedTime": "2026-11-15T12:00:00Z" },
                    "Root-1": { "stepCount": 1, "lastModifiedTime": "2026-11-15T12:00:05Z" },
                    "Sub-1": { "stepCount": 2, "lastModifiedTime": "2026-11-15T12:00:20Z", "trajectoryMetadata": { "rootConversationId": "Root-1" } }
                  }
                }
                """#)
            case lsPrefix + "GetCascadeTrajectory":
                let cid = ((try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])?["cascadeId"] as? String ?? "").lowercased()
                switch cid {
                case "old-offline":
                    return jsonResponse(#"""
                    {
                      "trajectory": {
                        "numTotalSteps": 1,
                        "steps": [
                          {
                            "status": "CORTEX_STEP_STATUS_DONE",
                            "metadata": {
                              "sourceTrajectoryStepInfo": { "stepIndex": 0 },
                              "createdAt": "2026-11-15T11:58:00Z",
                              "finishedGeneratingAt": "2026-11-15T11:58:10Z",
                              "modelUsage": { "model": "MODEL_PLACEHOLDER_M18", "inputTokens": "10", "outputTokens": "500" }
                            }
                          }
                        ]
                      }
                    }
                    """#)
                case "root-1":
                    return jsonResponse(#"""
                    {
                      "trajectory": {
                        "numTotalSteps": 1,
                        "steps": [
                          {
                            "status": "CORTEX_STEP_STATUS_DONE",
                            "invokeSubagent": { "results": [ { "conversationId": "Sub-1" } ] },
                            "metadata": {
                              "sourceTrajectoryStepInfo": { "stepIndex": 0 },
                              "createdAt": "2026-11-15T12:00:03Z",
                              "finishedGeneratingAt": "2026-11-15T12:00:05Z",
                              "generatorMetadata": [ { "chatModel": { "timeToFirstToken": "0.5s" } } ],
                              "modelUsage": { "model": "MODEL_PLACEHOLDER_M18", "inputTokens": "10", "outputTokens": "100" }
                            }
                          }
                        ]
                      }
                    }
                    """#)
                case "sub-1":
                    if p == 1 {
                        return jsonResponse(#"""
                        {
                          "trajectory": {
                            "numTotalSteps": 1,
                            "steps": [
                              {
                                "status": "CORTEX_STEP_STATUS_DONE",
                                "metadata": {
                                  "sourceTrajectoryStepInfo": { "stepIndex": 0 },
                                  "createdAt": "2026-11-15T12:00:06Z",
                                  "finishedGeneratingAt": "2026-11-15T12:00:10Z",
                                  "generatorMetadata": [ { "chatModel": { "timeToFirstToken": "1.0s" } } ],
                                  "modelUsage": { "model": "MODEL_PLACEHOLDER_M35", "inputTokens": "10", "outputTokens": "200" }
                                }
                              }
                            ]
                          }
                        }
                        """#)
                    }
                    return jsonResponse(#"""
                    {
                      "trajectory": {
                        "numTotalSteps": 2,
                        "steps": [
                          {
                            "status": "CORTEX_STEP_STATUS_DONE",
                            "metadata": {
                              "sourceTrajectoryStepInfo": { "stepIndex": 0 },
                              "createdAt": "2026-11-15T12:00:06Z",
                              "finishedGeneratingAt": "2026-11-15T12:00:10Z",
                              "generatorMetadata": [ { "chatModel": { "timeToFirstToken": "1.0s" } } ],
                              "modelUsage": { "model": "MODEL_PLACEHOLDER_M35", "inputTokens": "10", "outputTokens": "200" }
                            }
                          },
                          {
                            "status": "CORTEX_STEP_STATUS_DONE",
                            "metadata": {
                              "sourceTrajectoryStepInfo": { "stepIndex": 1 },
                              "createdAt": "2026-11-15T12:00:18Z",
                              "finishedGeneratingAt": "2026-11-15T12:00:20Z",
                              "modelUsage": { "model": "MODEL_PLACEHOLDER_M35", "inputTokens": "0", "outputTokens": "140" }
                            }
                          }
                        ]
                      }
                    }
                    """#)
                default:
                    return jsonResponse("{}", status: 404)
                }
            default:
                return jsonResponse("{}", status: 404)
            }
        }

        var env = home.environment
        env.transport = transport

        let baseNow = try unwrap(AntigravityModelResolver.parseISO8601("2026-11-15T12:00:00Z"))
        let emitted = LockedBox<[AntigravityLiveSpeed?]>([])
        let ledgerURL = home.url.appendingPathComponent("ledger.sqlite")

        let recorder = TokenUsageRecorder(
            environment: env,
            ledgerURL: ledgerURL,
            latency: 0.05,
            antigravityDebounce: 0.05,
            now: { baseNow },
            attribute: { _ in },
            onAntigravityLiveSpeed: { speed in
                emitted.value.append(speed)
            })
        recorder.setAntigravityWatching(enabled: true)
        defer { recorder.stop() }

        func touchConv(_ name: String, _ content: String) throws {
            try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: convDir.appendingPathComponent(name))
        }

        // Phase 1: Root-1 + Sub-1 merged (100/2s + 200/4s -> latest=50, avg=50, ttft=1.0)
        try touchConv("sub-1.pb", "p1")
        try expect(waitUntil { (emitted.value.last ?? nil) != nil }, "首轮应发出非空实时速度")
        let s1 = try unwrap(emitted.value.last ?? nil)
        try expectEqual(s1.email, "usera@example.com")
        try expect(abs(s1.latestTokPerSec - 50.0) < 1e-9, "首轮最新 TPS 应为 50.0")
        try expectEqual(s1.latestTtftSec, 1.0)
        try expect(abs(s1.sessionAvgTokPerSec - 50.0) < 1e-9, "首轮均值 TPS 应为 50.0")

        // Verify SQLite schema stays v5 and no speed columns/tables exist
        let schemaOk: Bool = try recorder.read { ledger in
            let ver = try ledger.db.prepare("PRAGMA user_version")
            _ = try ver.step()
            let tables = try ledger.db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
            var names: [String] = []
            while try tables.step() {
                if let n = tables.text(0) { names.append(n) }
            }
            return ver.int(0) == 5 && !names.contains(where: { $0.lowercased().contains("speed") })
        }
        try expect(schemaOk, "实时速度不得持久化到 SQLite，且 PRAGMA user_version 保持 5")

        // Phase 2: Only Sub-1 changes (Root-1 unchanged, NOT re-fetched!) -> Root-1 still merged from memory cache!
        let countBeforeP2 = emitted.value.count
        let fetchesBeforeP2 = transport.fetchedCascadeIDs().count
        phase.value = 2
        try touchConv("sub-1.pb", "p2")
        try expect(waitUntil { emitted.value.count > countBeforeP2 }, "Sub-1 变更应发出更新后的实时速度")
        let s2 = try unwrap(emitted.value.last ?? nil)
        let fetchedInP2 = Array(transport.fetchedCascadeIDs().dropFirst(fetchesBeforeP2)).map { $0.lowercased() }
        try expectEqual(fetchedInP2, ["sub-1"], "Root-1 水位线未变不得重复拉取")
        try expect(abs(s2.latestTokPerSec - 70.0) < 1e-9, "Sub-1 新步 140/2s 应得 70.0 tok/s")
        try expectEqual(s2.latestTtftSec, nil, "最新步缺 TTFT 应为 nil")
        try expect(abs(s2.sessionAvgTokPerSec - 55.0) < 1e-9, "缓存 Root-1 (100/2s) + Sub-1 (200/4s + 140/2s) = 440/8s = 55.0")

        // Phase 3: Switch online user to UserB (Root-1 is bound to UserA, Old-Offline < startedAt - 30s) -> emits nil
        let countBeforeP3 = emitted.value.count
        currentEmail.value = "UserB@Example.com"
        try touchConv("sub-1.pb", "p3-switch")
        try expect(waitUntil { emitted.value.count > countBeforeP3 }, "切号后无本账号有效样本应触发更新")
        try expect((emitted.value.last ?? nil) == nil, "切到无有效样本的 UserB 后应发出 nil")

        // Phase 4: Sign back UserA -> emits s2 again; then sign out (no email) -> emits nil; then sign back UserA; then server goes offline -> emits nil
        let countBeforeP4a = emitted.value.count
        currentEmail.value = "UserA@Example.com"
        try touchConv("sub-1.pb", "p4-back")
        try expect(waitUntil { emitted.value.count > countBeforeP4a && (emitted.value.last ?? nil) != nil }, "切回 UserA 应恢复有效速度")

        let countBeforeP4SignOut = emitted.value.count
        currentEmail.value = nil
        try touchConv("sub-1.pb", "p4-signout")
        try expect(waitUntil { emitted.value.count > countBeforeP4SignOut }, "退出登录后同步应触发更新")
        try expect((emitted.value.last ?? nil) == nil, "GetUserStatus 无邮箱时应立即发出 nil")

        let countBeforeP4ReSignIn = emitted.value.count
        currentEmail.value = "UserA@Example.com"
        try touchConv("sub-1.pb", "p4-resignin")
        try expect(waitUntil { emitted.value.count > countBeforeP4ReSignIn && (emitted.value.last ?? nil) != nil }, "重新登录后应恢复有效速度")

        let countBeforeP4b = emitted.value.count
        serverOffline.value = true
        try touchConv("sub-1.pb", "p4-offline")
        try expect(waitUntil { emitted.value.count > countBeforeP4b }, "服务端离线后同步应触发更新")
        try expect((emitted.value.last ?? nil) == nil, "Antigravity 离线后应立即发出 nil")

        // Phase 5: Server back online, then stop watching (last card deleted) -> immediately emits nil
        let countBeforeP5a = emitted.value.count
        serverOffline.value = false
        try touchConv("sub-1.pb", "p5-online")
        try expect(waitUntil { emitted.value.count > countBeforeP5a && (emitted.value.last ?? nil) != nil }, "恢复在线后应重新发出速度")

        let countBeforeP5b = emitted.value.count
        recorder.setAntigravityWatching(enabled: false)
        try expect(waitUntil { emitted.value.count > countBeforeP5b }, "关闭监听应触发清空通知")
        try expect((emitted.value.last ?? nil) == nil, "关闭监听（删光卡片）后应立即发出 nil")
    }

    static func idleRevalidationAndAppTermination() throws {
        let home = try TempHome()
        defer { home.remove() }
        let convDir = home.url.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
        let procs = home.antigravityProcesses
        procs.run(pid: 8802, startedAt: 200, token: "tok-idle", ports: [45002])

        let lsPrefix = "/exa.language_server_pb.LanguageServerService/"
        let currentEmail = LockedBox<String?>("UserA@Example.com")
        let serverOffline = LockedBox(false)

        let transport = ScriptedTransport { req in
            if serverOffline.value {
                return jsonResponse("{}", status: 503)
            }
            let email = currentEmail.value
            switch req.url?.path {
            case lsPrefix + "GetUserStatus":
                if let email {
                    return jsonResponse(#"{"userStatus":{"email":"\#(email)"}}"#)
                }
                return jsonResponse(#"{"userStatus":{}}"#)
            case lsPrefix + "GetAllCascadeTrajectories":
                return jsonResponse(#"""
                {
                  "trajectorySummaries": {
                    "Root-Idle": { "stepCount": 1, "lastModifiedTime": "2026-11-15T12:00:05Z" }
                  }
                }
                """#)
            case lsPrefix + "GetCascadeTrajectory":
                return jsonResponse(#"""
                {
                  "trajectory": {
                    "numTotalSteps": 1,
                    "steps": [
                      {
                        "status": "CORTEX_STEP_STATUS_DONE",
                        "metadata": {
                          "sourceTrajectoryStepInfo": { "stepIndex": 0 },
                          "createdAt": "2026-11-15T12:00:03Z",
                          "finishedGeneratingAt": "2026-11-15T12:00:05Z",
                          "modelUsage": { "model": "MODEL_PLACEHOLDER_M18", "inputTokens": "10", "outputTokens": "100" }
                        }
                      }
                    ]
                  }
                }
                """#)
            default:
                return jsonResponse("{}", status: 404)
            }
        }

        var env = home.environment
        env.transport = transport

        let baseNow = try unwrap(AntigravityModelResolver.parseISO8601("2026-11-15T12:00:00Z"))
        let emitted = LockedBox<[AntigravityLiveSpeed?]>([])
        let recorder = TokenUsageRecorder(
            environment: env,
            ledgerURL: home.url.appendingPathComponent("ledger.sqlite"),
            latency: 0.05,
            antigravityDebounce: 0.05,
            now: { baseNow },
            attribute: { _ in },
            onAntigravityLiveSpeed: { speed in
                emitted.value.append(speed)
            })
        recorder.setAntigravityWatching(enabled: true)
        defer { recorder.stop() }

        func touchConv(_ content: String) throws {
            try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: convDir.appendingPathComponent("root-idle.pb"))
        }

        // 1) liveSpeed == nil 时重校验不得扫进程也不得发任何传输请求
        recorder.revalidateAntigravityLiveSpeedIfNeeded()
        try recorder.read { _ in }
        try expectEqual(procs.listCalls, 0, "liveSpeed 为 nil 时重校验不得扫进程")
        try expectEqual(transport.requests.count, 0, "liveSpeed 为 nil 时重校验不得发任何 RPC")
        try expectEqual(emitted.value.count, 0)

        // 建立在线实时速度（liveSpeed != nil）
        try touchConv("init")
        try expect(waitUntil { (emitted.value.last ?? nil) != nil }, "首次 FSEvent 应建立有效实时速度")
        let initialFetches = transport.fetchedCascadeIDs().count
        try expectEqual(initialFetches, 1)

        // 2a) 空闲期间登出（无 FSEvent）-> 重校验发出 nil；之后再次重校验零请求
        let beforeSignOutCount = emitted.value.count
        currentEmail.value = nil
        recorder.revalidateAntigravityLiveSpeedIfNeeded()
        try recorder.read { _ in }
        try expectEqual(emitted.value.count, beforeSignOutCount + 1)
        try expect((emitted.value.last ?? nil) == nil, "空闲登出后重校验应立即发出 nil")

        let reqsAfterSignOut = transport.requests.count
        let scansAfterSignOut = procs.listCalls
        recorder.revalidateAntigravityLiveSpeedIfNeeded()
        try recorder.read { _ in }
        try expectEqual(transport.requests.count, reqsAfterSignOut, "归 nil 后再次重校验不得发传输请求")
        try expectEqual(procs.listCalls, scansAfterSignOut, "归 nil 后再次重校验不得扫进程")

        // 2b) 恢复在线速度 -> 空闲期间切号至 UserB（无 FSEvent）-> 重校验发出 nil
        let beforeRestore1 = emitted.value.count
        currentEmail.value = "UserA@Example.com"
        try touchConv("restore-1")
        try expect(waitUntil { emitted.value.count > beforeRestore1 && (emitted.value.last ?? nil) != nil }, "切回 UserA 应恢复实时速度")

        let beforeSwitchCount = emitted.value.count
        currentEmail.value = "UserB@Example.com"
        recorder.revalidateAntigravityLiveSpeedIfNeeded()
        try recorder.read { _ in }
        try expectEqual(emitted.value.count, beforeSwitchCount + 1)
        try expect((emitted.value.last ?? nil) == nil, "空闲切号到无样本账号后重校验应立即发出 nil")

        // 2c) 恢复在线速度 -> 空闲期间服务端离线（无 FSEvent）-> 重校验发出 nil
        let beforeRestore2 = emitted.value.count
        currentEmail.value = "UserA@Example.com"
        try touchConv("restore-2")
        try expect(waitUntil { emitted.value.count > beforeRestore2 && (emitted.value.last ?? nil) != nil }, "恢复在线应重新发出实时速度")

        let beforeOfflineCount = emitted.value.count
        serverOffline.value = true
        recorder.revalidateAntigravityLiveSpeedIfNeeded()
        try recorder.read { _ in }
        try expectEqual(emitted.value.count, beforeOfflineCount + 1)
        try expect((emitted.value.last ?? nil) == nil, "空闲服务端离线后重校验应立即发出 nil")

        // 3) 恢复在线速度 -> handleAntigravityAppTerminated() 零 RPC 清空，再悬停零 RPC，之后恢复写入仍沿用既有监听与水位线
        let beforeRestore3 = emitted.value.count
        serverOffline.value = false
        try touchConv("restore-3")
        try expect(waitUntil { emitted.value.count > beforeRestore3 && (emitted.value.last ?? nil) != nil }, "服务端恢复在线应发出实时速度")

        let countBeforeTerm = emitted.value.count
        let reqsBeforeTerm = transport.requests.count
        let scansBeforeTerm = procs.listCalls
        recorder.handleAntigravityAppTerminated()
        try recorder.read { _ in }
        try expectEqual(emitted.value.count, countBeforeTerm + 1, "App 退出应立即发出 nil")
        try expect((emitted.value.last ?? nil) == nil, "App 退出最后发出的速度应为 nil")
        try expectEqual(transport.requests.count, reqsBeforeTerm, "App 退出通知处理不得发任何 RPC")
        try expectEqual(procs.listCalls, scansBeforeTerm, "App 退出通知处理不得扫描进程")

        recorder.revalidateAntigravityLiveSpeedIfNeeded()
        try recorder.read { _ in }
        try expectEqual(transport.requests.count, reqsBeforeTerm, "App 退出清 nil 后再悬停不得发任何 RPC")
        try expectEqual(procs.listCalls, scansBeforeTerm, "App 退出清 nil 后再悬停不得扫描进程")

        // 监听、FSEvents 流与水位线仍完好：再次写入无需重复拉取未变轨迹，仅重探句柄后恢复速度
        let countBeforeRelaunch = emitted.value.count
        try touchConv("relaunch")
        try expect(waitUntil { emitted.value.count > countBeforeRelaunch && (emitted.value.last ?? nil) != nil },
                   "App 重启继续对话时现有 FSEvents 与水位线应继续生效")
        try expectEqual(procs.listCalls, scansBeforeTerm + 1, "handle 清空后新事件应重探一次进程句柄")
        try expectEqual(transport.fetchedCascadeIDs().count, initialFetches, "既有水位线保留，未变轨迹不得重复拉取")
    }
}
