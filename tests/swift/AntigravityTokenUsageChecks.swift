// Antigravity 桌面端轨迹模型解析、步骤提取与增量入账（antigravity-usage ticket 02）。
// 不碰真实进程或用户 ~/.gemini/antigravity 目录，全部通过夹具 JSON、TempHome、FakeAntigravityProcesses 与 FakeUsageTransport 注入。

import Foundation

final class AntigravityTokenUsageChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("步骤提取：只收 DONE 且非零用量；retryInfos 兜底不叠加；output 不叠加 thinking；纳秒与时区解析；截断保护", stepExtraction),
            Check("模型归一化：五级优先级、clientModelConfigs 与 responseModel 映射、未知占位符原样保留、CHECKPOINT 邻居推断", modelNormalization),
            Check("账本入账与归属：保持 user_version=5、30s 启动分界线、绑定稳定性、子代理继承、去重与隔离清理", ledgerAttributionAndDedup),
            Check("监听门控与防抖：默认关闭、开启空闲不轮询、突发写入合并为 1 次 RPC、关闭销毁并重置缓存", consentGateAndDebounce),
            Check("进程句柄缓存与重探测：稳态不重扫进程、未变轨迹跳过拉取、失败清缓存重探并支持未入榜邮箱", handleCacheAndErrorReprobe),
            Check("截断重试与子代理端到端：截断不推进水位线、invokeSubagent 与摘要父子串联实时入账", truncationWatermarkAndSubagentEndToEnd),
        ]
    }

    static func stepExtraction() throws {
        let userStatusData = Data(#"""
        {
          "userStatus": {
            "email": "User@Example.com",
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini 4 Carbon (High)",
                  "modelOrAlias": { "model": "MODEL_PLACEHOLDER_M429" }
                }
              ]
            }
          }
        }
        """#.utf8)
        let status = AntigravityModelResolver.parseUserStatus(userStatusData)
        try expectEqual(status.email, "User@Example.com")

        // 1) 截断保护：numTotalSteps > steps.count（支持字符串与整数，支持顶层或 trajectory 包装）
        let truncatedData = Data(#"""
        {
          "trajectory": {
            "numTotalSteps": "3",
            "steps": [
              { "status": "CORTEX_STEP_STATUS_DONE", "metadata": { "modelUsage": { "inputTokens": "10", "outputTokens": "5" } } },
              { "status": "CORTEX_STEP_STATUS_DONE", "metadata": { "modelUsage": { "inputTokens": "10", "outputTokens": "5" } } }
            ]
          }
        }
        """#.utf8)
        let truncated = AntigravityModelResolver.extractSteps(
            cascadeID: "Case-ABC",
            trajectoryData: truncatedData,
            summaryLastModifiedAt: nil,
            summaryParentID: nil,
            summaryRootID: nil,
            dynamicModels: status.dynamicModels)
        try expectEqual(truncated, .truncated, "numTotalSteps > steps.count 时整条轨迹跳过且不推进水位线")

        // 2) 完整轨迹：DONE vs RUNNING、modelUsage vs retryInfos、thinking 不叠加、纳秒与 +09:00 时区、
        //    finishedGeneratingAt > completedAt > createdAt > summary.lastModifiedTime、stepIndex 去重
        let fullData = Data(#"""
        {
          "trajectory": {
            "numTotalSteps": 5,
            "steps": [
              {
                "status": "CORTEX_STEP_STATUS_DONE",
                "metadata": {
                  "sourceTrajectoryStepInfo": { "stepIndex": 10 },
                  "createdAt": "2026-11-15T01:00:00Z",
                  "completedAt": "2026-11-15T01:00:02Z",
                  "finishedGeneratingAt": "2026-11-15T10:00:05.123456789+09:00",
                  "modelUsage": {
                    "model": "MODEL_PLACEHOLDER_M429",
                    "inputTokens": "100",
                    "outputTokens": "40",
                    "thinkingOutputTokens": "15",
                    "cacheReadTokens": "500"
                  },
                  "retryInfos": [
                    { "usage": { "model": "MODEL_PLACEHOLDER_M26", "inputTokens": "999", "outputTokens": "999" } }
                  ]
                }
              },
              {
                "status": "CORTEX_STEP_STATUS_DONE",
                "metadata": {
                  "createdAt": "2026-11-15T01:05:00Z",
                  "retryInfos": [
                    { "usage": { "model": "MODEL_PLACEHOLDER_M26", "inputTokens": 25, "outputTokens": 12, "cacheReadTokens": 30 } },
                    { "usage": { "model": "MODEL_PLACEHOLDER_M26", "inputTokens": 888, "outputTokens": 888 } }
                  ]
                }
              },
              {
                "status": "CORTEX_STEP_STATUS_RUNNING",
                "metadata": {
                  "finishedGeneratingAt": "2026-11-15T01:06:00Z",
                  "modelUsage": { "model": "MODEL_PLACEHOLDER_M429", "inputTokens": "50", "outputTokens": "50" }
                }
              },
              {
                "status": "CORTEX_STEP_STATUS_DONE",
                "metadata": {
                  "finishedGeneratingAt": "2026-11-15T01:07:00Z",
                  "modelUsage": { "model": "MODEL_PLACEHOLDER_M429", "inputTokens": "0", "outputTokens": "0", "cacheReadTokens": "0" }
                }
              },
              {
                "status": "CORTEX_STEP_STATUS_DONE",
                "metadata": {
                  "sourceTrajectoryStepInfo": { "stepIndex": 14 },
                  "modelUsage": { "model": "MODEL_PLACEHOLDER_M18", "inputTokens": -5, "outputTokens": 7 }
                }
              }
            ]
          }
        }
        """#.utf8)

        let summaryFallback = Date(timeIntervalSince1970: 1_794_700_000)
        let extracted = AntigravityModelResolver.extractSteps(
            cascadeID: "Cascade-XYZ",
            trajectoryData: fullData,
            summaryLastModifiedAt: summaryFallback,
            summaryParentID: nil,
            summaryRootID: nil,
            dynamicModels: status.dynamicModels)

        guard case .complete(let batch) = extracted else {
            throw CheckFailure(description: "完整轨迹不应被判为截断")
        }
        try expectEqual(batch.steps.count, 3, "跳过 RUNNING 和 0-token 步骤")

        // Step 0: stepIndex 10, finishedGeneratingAt 2026-11-15T10:00:05.123456789+09:00 == 01:00:05.123456789Z
        let expected0 = try unwrap(AntigravityModelResolver.parseISO8601("2026-11-15T01:00:05.123456789Z"))
        let step0 = batch.steps[0]
        try expectEqual(step0.messageID, "antigravity:cascade-xyz:10")
        try expectEqual(step0.sessionID, "cascade-xyz")
        try expectEqual(step0.model, "gemini-4-carbon-high")
        try expectEqual(step0.tokens, TokenCounts(input: 100, output: 40, cacheWrite: 0, cacheRead: 500))
        try expect(abs(step0.completedAt.timeIntervalSince(expected0)) < 1e-6, "纳秒与 +09:00 偏移精度应保留")

        // Step 1: retryInfos[0] 兜底，index 为数组下标 1，时间回落到 createdAt
        let expected1 = try unwrap(AntigravityModelResolver.parseISO8601("2026-11-15T01:05:00Z"))
        let step1 = batch.steps[1]
        try expectEqual(step1.messageID, "antigravity:cascade-xyz:1")
        try expectEqual(step1.model, "claude-opus-4-6-thinking")
        try expectEqual(step1.tokens, TokenCounts(input: 25, output: 12, cacheWrite: 0, cacheRead: 30))
        try expect(abs(step1.completedAt.timeIntervalSince(expected1)) < 1e-6, "createdAt 精确解析")

        // Step 4: 没有步骤时间时回落到 summary.lastModifiedTime，负值 clamp 到 0
        let step4 = batch.steps[2]
        try expectEqual(step4.messageID, "antigravity:cascade-xyz:14")
        try expectEqual(step4.model, "gemini-3-flash")
        try expectEqual(step4.tokens, TokenCounts(input: 0, output: 7, cacheWrite: 0, cacheRead: 0))
        try expect(abs(step4.completedAt.timeIntervalSince(summaryFallback)) < 1e-6, "summary.lastModifiedTime 兜底")
    }

    static func modelNormalization() throws {
        let userStatusData = Data(#"""
        {
          "userStatus": {
            "email": "u@example.com",
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini 4.5 Pro (High)",
                  "modelOrAlias": { "model": "MODEL_PLACEHOLDER_M998" },
                  "modelId": "gemini-4.5-pro-high"
                },
                {
                  "label": "Claude Sonnet 4.7 (Thinking)",
                  "modelOrAlias": { "model": "MODEL_PLACEHOLDER_M997" }
                }
              ]
            }
          }
        }
        """#.utf8)
        let status = AntigravityModelResolver.parseUserStatus(userStatusData)

        let data = Data(#"""
        {
          "steps": [
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 0 },
                "finishedGeneratingAt": "2026-11-15T02:00:00Z",
                "modelUsage": {
                  "model": "MODEL_PLACEHOLDER_M998",
                  "apiProvider": "API_PROVIDER_GOOGLE",
                  "inputTokens": "10", "outputTokens": "5"
                }
              }
            },
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "type": "CORTEX_STEP_TYPE_CHECKPOINT",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 1 },
                "finishedGeneratingAt": "2026-11-15T02:00:10Z",
                "modelUsage": {
                  "model": "MODEL_UNKNOWN",
                  "apiProvider": "API_PROVIDER_ANTHROPIC",
                  "inputTokens": "20", "outputTokens": "5"
                }
              }
            },
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "type": "CORTEX_STEP_TYPE_CHECKPOINT",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 2 },
                "finishedGeneratingAt": "2026-11-15T02:00:15Z",
                "modelUsage": {
                  "inputTokens": "30", "outputTokens": "5"
                }
              }
            },
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 3 },
                "finishedGeneratingAt": "2026-11-15T02:00:20Z",
                "generatorMetadata": [
                  { "chatModel": { "model": "MODEL_PLACEHOLDER_M997", "usage": { "apiProvider": "API_PROVIDER_ANTHROPIC" } } }
                ],
                "modelUsage": { "model": "0", "apiProvider": "API_PROVIDER_ANTHROPIC", "inputTokens": "11", "outputTokens": "2" }
              }
            },
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 4 },
                "finishedGeneratingAt": "2026-11-15T02:00:30Z",
                "generatorModel": "MODEL_PLACEHOLDER_M996",
                "modelUsage": { "inputTokens": "12", "outputTokens": "3" }
              }
            },
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 5 },
                "finishedGeneratingAt": "2026-11-15T02:00:40Z",
                "modelUsage": { "model": "MODEL_PLACEHOLDER_M995", "inputTokens": "13", "outputTokens": "4" }
              }
            },
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 6 },
                "finishedGeneratingAt": "2026-11-15T02:00:50Z",
                "modelUsage": { "model": "MODEL_PLACEHOLDER_M667", "inputTokens": "14", "outputTokens": "5" }
              }
            },
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 7 },
                "finishedGeneratingAt": "2026-11-15T02:01:00Z",
                "generatorMetadata": [
                  { "chatModel": { "responseModel": "claude-sonnet-4-7" } }
                ],
                "modelUsage": { "model": "MODEL_PLACEHOLDER_M35", "inputTokens": "15", "outputTokens": "6" }
              }
            }
          ],
          "generatorMetadata": [
            {
              "stepIndices": [4],
              "chatModel": { "responseModel": "claude-sonnet-4-6" }
            }
          ],
          "metadata": {
            "rootConversationId": "Root-Conv-1",
            "parentConversationId": "Parent-Conv-1"
          }
        }
        """#.utf8)

        let result = AntigravityModelResolver.extractSteps(
            cascadeID: "Child-Conv-2",
            trajectoryData: data,
            summaryLastModifiedAt: nil,
            summaryParentID: nil,
            summaryRootID: nil,
            dynamicModels: status.dynamicModels)

        guard case .complete(let batch) = result else {
            throw CheckFailure(description: "应正常解析")
        }
        try expectEqual(batch.parentSessionID, "root-conv-1")
        try expectEqual(batch.steps.map(\.model), [
            "gemini-4.5-pro-high",        // step 0: clientModelConfigs.modelId
            "claude-sonnet-4-7-thinking", // step 1: CHECKPOINT 同 Anthropic provider 后向借到 step 3
            "gemini-4.5-pro-high",        // step 2: CHECKPOINT 无 provider，step 1 不是显式捐赠者，向前借到 step 0
            "claude-sonnet-4-7-thinking", // step 3: inline chatModel.model + clientModelConfigs.label 归一化
            "claude-sonnet-4-6",          // step 4: 轨迹级 generatorMetadata chat.responseModel 兜底解析未知 M996
            "MODEL_PLACEHOLDER_M995",     // step 5: 动态/静态/responseModel 均无，原样保留
            "gemini-pro-orchestrator",    // step 6: 静态 PLACEHOLDER_MAP 映射 Orchestrator
            "claude-sonnet-4-7",          // step 7: 实时 chat.responseModel 优先于静态 staticPlaceholders[M35]
        ])

        // CHECKPOINT 带显式 API_PROVIDER_OPENAI 且周围仅有 API_PROVIDER_GOOGLE 步骤时，不得跨 provider 借用 Google 模型
        let crossProviderData = Data(#"""
        {
          "steps": [
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 0 },
                "finishedGeneratingAt": "2026-11-15T02:10:00Z",
                "modelUsage": {
                  "model": "MODEL_PLACEHOLDER_M18",
                  "apiProvider": "API_PROVIDER_GOOGLE",
                  "inputTokens": "10", "outputTokens": "5"
                }
              }
            },
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "type": "CORTEX_STEP_TYPE_CHECKPOINT",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 1 },
                "finishedGeneratingAt": "2026-11-15T02:10:10Z",
                "modelUsage": {
                  "apiProvider": "API_PROVIDER_OPENAI",
                  "inputTokens": "20", "outputTokens": "5"
                }
              }
            },
            {
              "status": "CORTEX_STEP_STATUS_DONE",
              "metadata": {
                "sourceTrajectoryStepInfo": { "stepIndex": 2 },
                "finishedGeneratingAt": "2026-11-15T02:10:20Z",
                "modelUsage": {
                  "model": "MODEL_PLACEHOLDER_M429",
                  "apiProvider": "API_PROVIDER_GOOGLE",
                  "inputTokens": "10", "outputTokens": "5"
                }
              }
            }
          ]
        }
        """#.utf8)
        guard case .complete(let crossBatch) = AntigravityModelResolver.extractSteps(
            cascadeID: "Cross-Provider-Check",
            trajectoryData: crossProviderData,
            summaryLastModifiedAt: nil,
            summaryParentID: nil,
            summaryRootID: nil,
            dynamicModels: [:]) else {
            throw CheckFailure(description: "跨 provider 检查轨迹应正常解析")
        }
        try expectEqual(crossBatch.steps.map(\.model), [
            "gemini-3-flash",
            "unknown",
            "gemini-4-carbon-high",
        ], "CHECKPOINT 显式 OpenAI provider 不得跨 provider 借用前后 Google 模型")
    }

    static func ledgerAttributionAndDedup() throws {
        let home = try TempHome()
        defer { home.remove() }
        let dbURL = home.url.appendingPathComponent("ledger.sqlite")
        let ledger = try TokenLedger(at: dbURL)

        func schemaVersion() throws -> Int {
            let st = try ledger.db.prepare("PRAGMA user_version")
            _ = try st.step()
            return st.int(0)
        }
        try expectEqual(try schemaVersion(), 5)

        let startedAt = Date(timeIntervalSince1970: 1_794_700_000)
        let cal = Calendar(identifier: .gregorian)

        func makeStep(session: String, idx: Int, at: Date, model: String = "gemini-4-carbon-high",
                      input: Int = 100, output: Int = 50, cacheRead: Int = 200) -> AntigravityTrajectoryStep {
            AntigravityTrajectoryStep(
                messageID: "antigravity:\(session.lowercased()):\(idx)",
                sessionID: session.lowercased(),
                stepIndex: idx,
                completedAt: at,
                createdAt: at,
                finishedAt: at,
                model: model,
                tokens: TokenCounts(input: input, output: output, cacheWrite: 0, cacheRead: cacheRead),
                isCompactionStep: false,
                timeToFirstTokenSec: nil)
        }

        // 1) 未绑定会话：早于 startedAt - 30s 的步骤记为 unattributed 且不绑定；恰好 -30s 在线则绑定
        let rootID = "conv-root-1"
        let childID = "conv-child-1"
        let batch1 = AntigravityExtractedBatch(
            sessionID: rootID,
            parentSessionID: nil,
            rootSessionID: nil,
            childCascadeIDs: [childID],
            steps: [
                makeStep(session: rootID, idx: 0, at: startedAt.addingTimeInterval(-31), input: 10, output: 5, cacheRead: 0),
                makeStep(session: rootID, idx: 1, at: startedAt.addingTimeInterval(-30), input: 100, output: 50, cacheRead: 200),
            ])
        let revBefore = ledger.revision
        let added1 = try ledger.ingest(antigravity: [batch1], onlineEmail: "UserA@Example.com", listenerStartedAt: startedAt)
        try expectEqual(added1, 2)
        try expectEqual(ledger.revision, revBefore + 1)
        try expectEqual(try schemaVersion(), 5, "PRAGMA user_version 必须保持 5")

        // 校验 messages.tool 列是字面量 'antigravity' 且 cache_write == 0
        let toolCheck = try ledger.db.prepare("SELECT tool, cache_write FROM messages WHERE message_id = 'antigravity:conv-root-1:1'")
        try expect(try toolCheck.step(), "应存在入账步骤")
        try expectEqual(toolCheck.text(0), "antigravity")
        try expectEqual(toolCheck.int(1), 0)

        // 重复摄入同一批次：INSERT OR IGNORE 幂等，revision 不涨
        let addedDup = try ledger.ingest(antigravity: [batch1], onlineEmail: "UserA@Example.com", listenerStartedAt: startedAt)
        try expectEqual(addedDup, 0)
        try expectEqual(ledger.revision, revBefore + 1)

        // 2) 切换账号为 UserB 后，同一根会话的子代理仍保持 UserA 归属（历史步骤不变）
        let childBatch = AntigravityExtractedBatch(
            sessionID: childID,
            parentSessionID: rootID,
            rootSessionID: rootID,
            childCascadeIDs: [],
            steps: [
                makeStep(session: childID, idx: 0, at: startedAt.addingTimeInterval(60),
                         model: "claude-sonnet-4-6", input: 40, output: 10, cacheRead: 0),
            ])
        let addedChild = try ledger.ingest(antigravity: [childBatch], onlineEmail: "UserB@Example.com", listenerStartedAt: startedAt)
        try expectEqual(addedChild, 1)

        let usageA = try ledger.accountUsage(
            "antigravity:usera@example.com", resets: KnownResets(fiveHour: nil, sevenDay: nil),
            now: startedAt.addingTimeInterval(120), calendar: cal)
        try expectEqual(usageA.cumulative.usage.tokens, TokenCounts(input: 140, output: 60, cacheWrite: 0, cacheRead: 200))
        let usageB = try ledger.accountUsage(
            "antigravity:userb@example.com", resets: KnownResets(fiveHour: nil, sevenDay: nil),
            now: startedAt.addingTimeInterval(120), calendar: cal)
        try expectEqual(usageB.cumulative.usage.tokens, TokenCounts.zero)

        let unattributed = try ledger.cumulativeUsage(account: nil)
        try expectEqual(unattributed.usage.tokens, TokenCounts(input: 10, output: 5, cacheWrite: 0, cacheRead: 0))

        // 3) 离线新会话（onlineEmail == nil）：新步骤记 unattributed 且不绑定；之后在线 UserC 发新步仅新步归属 UserC
        let offlineSession = "conv-offline-1"
        let offlineBatch = AntigravityExtractedBatch(
            sessionID: offlineSession, parentSessionID: nil, rootSessionID: nil, childCascadeIDs: [],
            steps: [makeStep(session: offlineSession, idx: 0, at: startedAt.addingTimeInterval(10), input: 20, output: 0, cacheRead: 0)])
        try expectEqual(try ledger.ingest(antigravity: [offlineBatch], onlineEmail: nil, listenerStartedAt: startedAt), 1)
        let onlineLaterBatch = AntigravityExtractedBatch(
            sessionID: offlineSession, parentSessionID: nil, rootSessionID: nil, childCascadeIDs: [],
            steps: [makeStep(session: offlineSession, idx: 1, at: startedAt.addingTimeInterval(20), input: 30, output: 0, cacheRead: 0)])
        try expectEqual(try ledger.ingest(antigravity: [onlineLaterBatch], onlineEmail: "Unadded@Example.com", listenerStartedAt: startedAt), 1)

        let usageC = try ledger.cumulativeUsage(account: "antigravity:unadded@example.com")
        try expectEqual(usageC.usage.tokens, TokenCounts(input: 30, output: 0, cacheWrite: 0, cacheRead: 0))
        try expectEqual(try ledger.cumulativeUsage(account: nil).usage.tokens,
                        TokenCounts(input: 30, output: 5, cacheWrite: 0, cacheRead: 0))

        // 4) 清空单个账号累计不影响其他账号，rolled_message_ids / forgotten_before 防重入
        try ledger.clearCumulative(account: "antigravity:usera@example.com", at: startedAt.addingTimeInterval(120))
        try expectEqual(try ledger.cumulativeUsage(account: "antigravity:usera@example.com").usage.tokens, TokenCounts.zero)
        try expectEqual(try ledger.cumulativeUsage(account: "antigravity:unadded@example.com").usage.tokens,
                        TokenCounts(input: 30, output: 0, cacheWrite: 0, cacheRead: 0))

        // 模拟 rollUp 后再重新传入旧消息（应被 rolled_message_ids 拦截，不重复入账）
        try ledger.rollUp(now: startedAt.addingTimeInterval(40 * 86_400), retentionDays: 30, calendar: cal)
        try expectEqual(try ledger.ingest(antigravity: [batch1], onlineEmail: "UserA@Example.com", listenerStartedAt: startedAt), 0)
    }

    // MARK: - Slice 4 Helpers & End-to-End Checks

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
        var handler: @Sendable (URLRequest) throws -> UsageHTTPResponse

        init(_ handler: @escaping @Sendable (URLRequest) throws -> UsageHTTPResponse) {
            self.handler = handler
        }

        var requests: [URLRequest] { lock.withLock { _requests } }

        func methods(named name: String) -> [URLRequest] {
            requests.filter { $0.url?.path.hasSuffix("/" + name) == true }
        }

        func send(_ request: URLRequest) throws -> UsageHTTPResponse {
            lock.withLock { _requests.append(request) }
            return try handler(request)
        }
    }

    private static let lsPrefix = "/exa.language_server_pb.LanguageServerService/"

    private static func jsonResponse(_ body: String, status: Int = 200) -> UsageHTTPResponse {
        UsageHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    private static func conversationsDir(home: TempHome) -> URL {
        home.url.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
    }

    private static func touchConversationFile(in dir: URL, name: String, content: String = "x") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: dir.appendingPathComponent(name))
    }

    private static func waitUntil(_ timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return predicate()
    }

    static func consentGateAndDebounce() throws {
        let home = try TempHome()
        defer { home.remove() }
        let convDir = conversationsDir(home: home)
        let procs = home.antigravityProcesses
        procs.run(pid: 901, startedAt: 100, token: "tok-1", ports: [41001])

        let transport = ScriptedTransport { req in
            switch req.url?.path {
            case lsPrefix + "GetUserStatus":
                return jsonResponse(#"{"userStatus":{"email":"Watch@Example.com"}}"#)
            case lsPrefix + "GetAllCascadeTrajectories":
                return jsonResponse(#"{"trajectorySummaries":{"c1":{"stepCount":1,"lastModifiedTime":"2026-11-15T10:00:00Z"}}}"#)
            case lsPrefix + "GetCascadeTrajectory":
                return jsonResponse(#"{"trajectory":{"numTotalSteps":1,"steps":[{"status":"CORTEX_STEP_STATUS_DONE","metadata":{"finishedGeneratingAt":"2026-11-15T10:00:00Z","modelUsage":{"model":"MODEL_PLACEHOLDER_M18","inputTokens":"10","outputTokens":"5"}}}]}}"#)
            default:
                throw URLError(.cannotConnectToHost)
            }
        }
        var env = home.environment
        env.transport = transport

        let baseNow = try unwrap(AntigravityModelResolver.parseISO8601("2026-11-15T10:00:00Z"))
        let updates = ProfileWatcherChecks.Counter()
        let recorder = TokenUsageRecorder(
            environment: env,
            ledgerURL: home.url.appendingPathComponent("ledger.sqlite"),
            latency: 0.05,
            antigravityDebounce: 0.05,
            now: { baseNow },
            attribute: { _ in },
            onUpdate: { updates.increment() })
        recorder.start()
        defer { recorder.stop() }
        try recorder.read { _ in }

        // 1) 默认关闭：写入 conversations 目录也不探测进程、不发任何 RPC
        try touchConversationFile(in: convDir, name: "c1.pb", content: "1")
        Thread.sleep(forTimeInterval: 0.2)
        try expectEqual(procs.listCalls, 0, "默认未开启 Antigravity 监听时不得扫描进程")
        try expectEqual(transport.requests.count, 0, "默认未开启 Antigravity 监听时不得发任何 RPC")

        // 2) false -> true 后空闲等待：绝不自动发轮询 RPC
        recorder.setAntigravityWatching(enabled: true)
        Thread.sleep(forTimeInterval: 0.2)
        try expectEqual(procs.listCalls, 0, "开启监听但 conversations 无变化时不得主动轮询")
        try expectEqual(transport.requests.count, 0)

        // 3) 短时间突发 5 次文件写入 -> 防抖合并为 1 次 RPC 同步
        let updatesBeforeBurst = updates.count
        for i in 0..<5 {
            try touchConversationFile(in: convDir, name: "c1.pb", content: "burst-\(i)")
            Thread.sleep(forTimeInterval: 0.005)
        }
        try expect(waitUntil { updates.count > updatesBeforeBurst }, "突发写入应触发 Antigravity 同步更新")
        Thread.sleep(forTimeInterval: 0.15)
        try expectEqual(procs.listCalls, 1)
        try expectEqual(transport.methods(named: "GetUserStatus").count, 1)
        try expectEqual(transport.methods(named: "GetAllCascadeTrajectories").count, 1)
        try expectEqual(transport.methods(named: "GetCascadeTrajectory").count, 1)

        // 验证 Connect 请求头与主库写入
        let firstReq = try unwrap(transport.methods(named: "GetUserStatus").first)
        try expectEqual(firstReq.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), "tok-1")
        try expectEqual(firstReq.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let usage = try recorder.accountUsage("antigravity:watch@example.com", resets: KnownResets(fiveHour: nil, sevenDay: nil))
        try expectEqual(usage.cumulative.usage.tokens, TokenCounts(input: 10, output: 5, cacheWrite: 0, cacheRead: 0))

        // 4) true -> false 立即停止监听并清空句柄与水位线缓存
        recorder.setAntigravityWatching(enabled: false)
        try touchConversationFile(in: convDir, name: "c1.pb", content: "after-off")
        Thread.sleep(forTimeInterval: 0.2)
        try expectEqual(procs.listCalls, 1, "关闭后不应再响应文件事件或扫进程")
        try expectEqual(transport.methods(named: "GetUserStatus").count, 1)

        // 5) 再次开启后写入：已重置句柄缓存与水位线，需重新扫描进程与拉取轨迹
        recorder.setAntigravityWatching(enabled: true)
        try touchConversationFile(in: convDir, name: "c1.pb", content: "after-re-enable")
        try expect(waitUntil { procs.listCalls == 2 }, "重新开启后清空过的缓存应重探进程")
        try expect(waitUntil { transport.methods(named: "GetCascadeTrajectory").count == 2 }, "清空水位线后应重新拉取轨迹")
    }

    static func handleCacheAndErrorReprobe() throws {
        let home = try TempHome()
        defer { home.remove() }
        let convDir = conversationsDir(home: home)
        let procs = home.antigravityProcesses
        procs.run(pid: 1001, startedAt: 10, token: "csrf-a", ports: [42001])

        let phase = LockedBox(1)

        let transport = ScriptedTransport { req in
            let currentPhase = phase.value
            let port = req.url?.port ?? 0
            if currentPhase == 4 && port == 42001 {
                return jsonResponse("{}", status: 503)
            }
            switch req.url?.path {
            case lsPrefix + "GetUserStatus":
                // 未在 AntigravityBoard 添加过的邮箱，同样照常入账（不建卡、不改 AntigravityBoard）
                return jsonResponse(#"{"userStatus":{"email":"Unlisted@Example.com"}}"#)
            case lsPrefix + "GetAllCascadeTrajectories":
                if currentPhase == 1 {
                    return jsonResponse(#"{"trajectorySummaries":{"c1":{"stepCount":1,"lastModifiedTime":"2026-11-15T11:00:00Z"}}}"#)
                }
                return jsonResponse(#"{"trajectorySummaries":{"c1":{"stepCount":1,"lastModifiedTime":"2026-11-15T11:00:00Z"},"c2":{"stepCount":1,"lastModifiedTime":"2026-11-15T11:05:00Z"}}}"#)
            case lsPrefix + "GetCascadeTrajectory":
                let cid = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])?["cascadeId"] as? String ?? ""
                if cid == "c1" {
                    return jsonResponse(#"{"steps":[{"status":"CORTEX_STEP_STATUS_DONE","metadata":{"finishedGeneratingAt":"2026-11-15T11:00:00Z","modelUsage":{"model":"MODEL_PLACEHOLDER_M18","inputTokens":"20","outputTokens":"10"}}}]}"#)
                }
                return jsonResponse(#"{"steps":[{"status":"CORTEX_STEP_STATUS_DONE","metadata":{"finishedGeneratingAt":"2026-11-15T11:05:00Z","modelUsage":{"model":"MODEL_PLACEHOLDER_M35","inputTokens":"50","outputTokens":"25"}}}]}"#)
            default:
                return jsonResponse("{}", status: 404)
            }
        }
        var env = home.environment
        env.transport = transport

        let baseNow = try unwrap(AntigravityModelResolver.parseISO8601("2026-11-15T11:00:00Z"))
        let recorder = TokenUsageRecorder(
            environment: env,
            ledgerURL: home.url.appendingPathComponent("ledger.sqlite"),
            latency: 0.05,
            antigravityDebounce: 0.05,
            now: { baseNow },
            attribute: { _ in })
        recorder.setAntigravityWatching(enabled: true)
        defer { recorder.stop() }

        // 第 1 次：冷启动探测 42001，拉 c1
        try touchConversationFile(in: convDir, name: "c1.pb", content: "1")
        try expect(waitUntil { transport.methods(named: "GetCascadeTrajectory").count == 1 }, "第 1 次应拉取 c1")
        try expectEqual(procs.listCalls, 1)

        // 第 2 次：c1 水位线未变 + 新增 c2 -> 稳态不重扫进程（listCalls 仍为 1），只拉 c2，不重拉 c1
        phase.value = 2
        try touchConversationFile(in: convDir, name: "c2.pb", content: "2")
        try expect(waitUntil { transport.methods(named: "GetCascadeTrajectory").count == 2 }, "第 2 次应拉取新增 c2")
        try expectEqual(procs.listCalls, 1, "稳态增量同步不得重扫进程")
        let fetchedCids = transport.methods(named: "GetCascadeTrajectory").compactMap {
            (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any])?["cascadeId"] as? String
        }
        try expectEqual(fetchedCids, ["c1", "c2"])

        // 第 3 次：什么都没变 -> 仍不重扫进程、不调用 GetCascadeTrajectory
        phase.value = 3
        try touchConversationFile(in: convDir, name: "c2.pb", content: "2b")
        try expect(waitUntil { transport.methods(named: "GetAllCascadeTrajectories").count == 3 }, "第 3 次应完成摘要比对")
        try expectEqual(procs.listCalls, 1)
        try expectEqual(transport.methods(named: "GetCascadeTrajectory").count, 2, "水位线未变不得重复调用 GetCascadeTrajectory")

        // 第 4 次：42001 返回 503 + 新进程在 42002 上线 -> 清缓存重探一次找到 42002
        procs.run(pid: 1002, startedAt: 20, token: "csrf-b", ports: [42002])
        phase.value = 4
        try touchConversationFile(in: convDir, name: "c2.pb", content: "3")
        try expect(waitUntil { procs.listCalls == 2 }, "旧端口返回非 200 后应重新探测进程")
        let tokenOn42002 = try unwrap(transport.requests.last { $0.url?.port == 42002 }?.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"))
        try expectEqual(tokenOn42002, "csrf-b")

        let unlistedUsage = try recorder.accountUsage("antigravity:unlisted@example.com", resets: KnownResets(fiveHour: nil, sevenDay: nil))
        try expectEqual(unlistedUsage.cumulative.usage.tokens, TokenCounts(input: 70, output: 35, cacheWrite: 0, cacheRead: 0))
        try expectEqual(AntigravityBoardStore(environment: env).load().emails, [], "未添加邮箱不得自动新建卡片")
    }

    static func truncationWatermarkAndSubagentEndToEnd() throws {
        let home = try TempHome()
        defer { home.remove() }
        let convDir = conversationsDir(home: home)
        home.antigravityProcesses.run(pid: 777, startedAt: 1, token: "tok", ports: [43001])

        let returnTruncatedParent = LockedBox(true)

        let transport = ScriptedTransport { req in
            let truncated = returnTruncatedParent.value
            switch req.url?.path {
            case lsPrefix + "GetUserStatus":
                return jsonResponse(#"{"userStatus":{"email":"SubUser@Example.com"}}"#)
            case lsPrefix + "GetAllCascadeTrajectories":
                return jsonResponse(#"{"trajectorySummaries":{"Parent-1":{"stepCount":2,"lastModifiedTime":"2026-11-15T12:00:00Z"}}}"#)
            case lsPrefix + "GetCascadeTrajectory":
                let cid = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])?["cascadeId"] as? String ?? ""
                if cid == "Parent-1" {
                    if truncated {
                        return jsonResponse(#"{"trajectory":{"numTotalSteps":2,"steps":[{"status":"CORTEX_STEP_STATUS_DONE","metadata":{"finishedGeneratingAt":"2026-11-15T12:00:00Z","modelUsage":{"model":"MODEL_PLACEHOLDER_M18","inputTokens":"10","outputTokens":"2"}}}]}}"#)
                    }
                    return jsonResponse(#"{"trajectory":{"numTotalSteps":2,"steps":[{"status":"CORTEX_STEP_STATUS_DONE","invokeSubagent":{"results":[{"conversationId":"Sub-1"}]},"metadata":{"sourceTrajectoryStepInfo":{"stepIndex":0},"finishedGeneratingAt":"2026-11-15T12:00:00Z","modelUsage":{"model":"MODEL_PLACEHOLDER_M18","inputTokens":"10","outputTokens":"2"}}},{"status":"CORTEX_STEP_STATUS_DONE","metadata":{"sourceTrajectoryStepInfo":{"stepIndex":1},"finishedGeneratingAt":"2026-11-15T12:00:10Z","modelUsage":{"model":"MODEL_PLACEHOLDER_M18","inputTokens":"20","outputTokens":"4"}}}]}}"#)
                }
                if cid.lowercased() == "sub-1" {
                    return jsonResponse(#"{"trajectory":{"numTotalSteps":1,"steps":[{"status":"CORTEX_STEP_STATUS_DONE","metadata":{"sourceTrajectoryStepInfo":{"stepIndex":0},"finishedGeneratingAt":"2026-11-15T12:00:05Z","modelUsage":{"model":"MODEL_PLACEHOLDER_M35","inputTokens":"30","outputTokens":"6"}}}]}}"#)
                }
                return jsonResponse("{}", status: 404)
            default:
                return jsonResponse("{}", status: 404)
            }
        }
        var env = home.environment
        env.transport = transport

        let baseNow = try unwrap(AntigravityModelResolver.parseISO8601("2026-11-15T12:00:00Z"))
        let updates = ProfileWatcherChecks.Counter()
        let recorder = TokenUsageRecorder(
            environment: env,
            ledgerURL: home.url.appendingPathComponent("ledger.sqlite"),
            latency: 0.05,
            antigravityDebounce: 0.05,
            now: { baseNow },
            attribute: { _ in },
            onUpdate: { updates.increment() })
        recorder.setAntigravityWatching(enabled: true)
        defer { recorder.stop() }

        // 1) 首轮截断：整条跳过、不推进水位线
        try touchConversationFile(in: convDir, name: "parent-1.pb", content: "part1")
        try expect(waitUntil { transport.methods(named: "GetCascadeTrajectory").count == 1 }, "首轮应请求 GetCascadeTrajectory")
        Thread.sleep(forTimeInterval: 0.1)
        try expectEqual(updates.count, 0)
        try expectEqual(
            try recorder.accountUsage("antigravity:subuser@example.com", resets: KnownResets(fiveHour: nil, sevenDay: nil)).cumulative.usage.tokens,
            TokenCounts.zero)

        // 2) 第二轮摘要未变（stepCount 仍是 2），因水位线未推进仍会重拉，同时顺带拉取 invokeSubagent("sub-1") 并串联父子归属
        returnTruncatedParent.value = false
        try touchConversationFile(in: convDir, name: "parent-1.pb", content: "part2")
        try expect(waitUntil { updates.count > 0 }, "补全后应重新拉取并入账")

        let total = try recorder.accountUsage("antigravity:subuser@example.com", resets: KnownResets(fiveHour: nil, sevenDay: nil))
        try expectEqual(total.cumulative.usage.tokens, TokenCounts(input: 60, output: 12, cacheWrite: 0, cacheRead: 0))

        // 校验子代理 parent_session_id = "parent-1"
        let parentCheck: String? = try recorder.read { ledger in
            let st = try ledger.db.prepare("SELECT parent_session_id FROM messages WHERE message_id = 'antigravity:sub-1:0'")
            _ = try st.step()
            return st.text(0)
        }
        try expectEqual(parentCheck, "parent-1")
    }
}
