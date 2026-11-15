// Antigravity 额度被动更新（antigravity-usage ticket 03）：
// - AntigravityBoard.recordPassive(_:) 仅消费成功快照：已添加邮箱替换快照、清掉原因、更新 lastReadEmail；
//   未添加邮箱不建卡、不存快照，仅推进 lastReadEmail 使旧卡片变灰。被动通道绝不设置 problem、.discarded 或短暂提示。
// - AntigravityTrajectoryCollector / TokenUsageRecorder 在对话 FSEvents 驱动下按 180 秒冷却发送空体 {} 的
//   RetrieveUserQuotaSummary（不含 forceRefresh），发起前即推进冷却时间戳，空闲或未开启监听零流量，
//   失败或不可识别响应静默保留旧快照；手动刷新保持 forceRefresh: true 及既有诊断逻辑不变。

import Foundation

final class AntigravityPassiveQuotaChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("recordPassive 已添加邮箱（不分大小写）：替换快照、清掉原因与 discarded、更新 lastReadEmail", recordPassiveMatchedEmail),
            Check("recordPassive 未添加邮箱：不建卡不存快照，只推进 lastReadEmail 使旧卡变灰并按变更返回 needsSave", recordPassiveUnmatchedEmail),
            Check("FSEvents 驱动被动请求：空闲与关闭门控零流量，WAL 空轨迹变更仍发空体 {}（无 forceRefresh）并回调额度", passiveFetchOnFSEventsAndEmptyChanges),
            Check("180 秒冷却节流与失败冷却：发起前推进时间戳，失败/不可识别响应同样冷却，关闭重置冷却，未登录不消耗冷却", passiveCooldownAndReset),
            Check("被动异常静默保旧与手动刷新无回归：被动错误不设 problem 或 discarded；手动仍发 forceRefresh: true 并正常诊断", passiveSilentIgnoreAndManualRegression),
        ]
    }

    static let now = fixedNow
    static func at(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
    static func at(seconds: Double) -> Date { now.addingTimeInterval(seconds) }

    static func recordPassiveMatchedEmail() throws {
        let typed = "Ultra@Example.com"
        let pro = AntigravityBoardChecks.pro
        var board = AntigravityBoardChecks.added(typed, pro)
        board.record(.success(AntigravityBoardChecks.ultraQuota(email: typed, gemini5h: 25, fetchedAt: now)), clicked: nil)
        board.record(.failed(email: typed, reason: .httpStatus(503)), clicked: typed)
        board.record(.notSignedIn, clicked: pro)
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.problem), [.failed(.httpStatus(503)), .notSignedIn])

        // 被动更新匹配到已添加邮箱（大小写不同）：替换快照、清掉自身与不知道账号的原因、保持添加时的邮箱写法
        let passive = AntigravityBoardChecks.ultraQuota(email: "ultra@example.com", gemini5h: 82.9, fetchedAt: at(minutes: 2))
        let needsSave = board.recordPassive(passive)
        try expectEqual(needsSave, true)
        try expectEqual(board.lastReadEmail, typed)

        let cards = board.cards(now: at(minutes: 3))
        try expectEqual(cards.map(\.email), [typed, pro])
        try expectEqual(cards[0].isOldSnapshot, false)
        try expectEqual(cards[0].fetchedAt, at(minutes: 2))
        try expectEqual(cards[0].groups[0].buckets[0].reading, .remaining(82, tint: .green))
        try expectEqual(cards.map(\.problem), [nil, nil], "自身原因与不知道账号的原因都应清掉")

        // 先前手动格式无法识别丢掉数据时，被动成功同样恢复快照并清掉 .discarded
        board.record(.unrecognizedFormat(email: typed), clicked: typed)
        try expectEqual(board.cards(now: at(minutes: 4))[0].problem, .unrecognizedFormat)
        try expectEqual(board.cards(now: at(minutes: 4))[0].groups, [])
        let recovered = AntigravityBoardChecks.ultraQuota(email: "ULTRA@example.com", gemini5h: 61, fetchedAt: at(minutes: 5))
        try expectEqual(board.recordPassive(recovered), true)
        let afterRecovery = board.cards(now: at(minutes: 6))[0]
        try expectEqual(afterRecovery.problem, nil)
        try expectEqual(afterRecovery.groups.count, 2)
        try expectEqual(afterRecovery.groups[0].buckets[0].reading, .remaining(61, tint: .green))
    }

    static func recordPassiveUnmatchedEmail() throws {
        let ultra = AntigravityBoardChecks.ultra
        let pro = AntigravityBoardChecks.pro
        let other = "other@example.com"
        var board = AntigravityBoardChecks.added(ultra, pro)
        board.record(.success(AntigravityBoardChecks.ultraQuota(fetchedAt: now)), clicked: nil)
        board.record(.failed(email: ultra, reason: .networkFailure), clicked: ultra)
        board.record(.notSignedIn, clicked: pro)
        let savedBefore = board.saved
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.isOldSnapshot), [false, true])

        // 未添加邮箱：不建卡、不存它的额度，但清掉不知道账号的原因并推进 lastReadEmail，使旧卡全部变灰
        let firstNeedsSave = board.recordPassive(AntigravityBoardChecks.ultraQuota(email: other, gemini5h: 99, fetchedAt: at(minutes: 2)))
        try expectEqual(firstNeedsSave, true)
        try expectEqual(board.emails, [ultra, pro])
        try expectEqual(board.saved, savedBefore, "不得保存未添加邮箱的快照")
        try expectEqual(board.lastReadEmail, other)
        let cards = board.cards(now: at(minutes: 3))
        try expectEqual(cards.map(\.isOldSnapshot), [true, true])
        try expectEqual(cards.map(\.problem), [.failed(.networkFailure), nil], "只清掉不知道账号的原因，保留 ultra 自身原因")

        // 同一未添加邮箱再次被动到达且没有清掉任何问题：lastReadEmail 未变 -> needsSave == false
        let repeatNeedsSave = board.recordPassive(AntigravityBoardChecks.ultraQuota(email: other, gemini5h: 50, fetchedAt: at(minutes: 5)))
        try expectEqual(repeatNeedsSave, false)
        try expectEqual(board.saved, savedBefore)

        // 若此时存在不知道账号的原因，即使 lastReadEmail 仍是同一未添加邮箱，清掉原因也返回 needsSave == true
        board.record(.notSignedIn, clicked: pro)
        try expectEqual(board.cards(now: at(minutes: 6)).map(\.problem), [.failed(.networkFailure), .notSignedIn])
        let clearedOnlySave = board.recordPassive(AntigravityBoardChecks.ultraQuota(email: other, gemini5h: 40, fetchedAt: at(minutes: 6)))
        try expectEqual(clearedOnlySave, true)
        try expectEqual(board.cards(now: at(minutes: 6)).map(\.problem), [.failed(.networkFailure), nil])
    }

    // MARK: - 被动抓取辅助

    private static let lsPrefix = "/exa.language_server_pb.LanguageServerService/"

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value
        init(_ value: Value) { storage = value }
        var value: Value {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
        func mutate(_ body: (inout Value) -> Void) {
            lock.withLock { body(&storage) }
        }
    }

    private final class ScriptedTransport: UsageTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var handler: @Sendable (URLRequest) throws -> UsageHTTPResponse
        init(_ handler: @escaping @Sendable (URLRequest) throws -> UsageHTTPResponse) { self.handler = handler }
        var requests: [URLRequest] { lock.withLock { _requests } }
        func methods(named name: String) -> [URLRequest] {
            requests.filter { $0.url?.path.hasSuffix("/" + name) == true }
        }
        func send(_ request: URLRequest) throws -> UsageHTTPResponse {
            lock.withLock { _requests.append(request) }
            return try handler(request)
        }
    }

    private static func jsonResponse(_ body: String, status: Int = 200) -> UsageHTTPResponse {
        UsageHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    private static func touchConversationFile(in home: TempHome, name: String = "wal.pb", content: String = "tick") throws {
        let dir = home.url.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
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

    private static func fixture(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("tests/fixtures/antigravity/\(name).json"), encoding: .utf8)
    }

    static func passiveFetchOnFSEventsAndEmptyChanges() throws {
        let home = try TempHome()
        defer { home.remove() }
        home.antigravityProcesses.run(pid: 801, startedAt: 100, token: "passive-tok", ports: [45001])

        let statusJSON = try fixture("get-user-status-ultra-2026-11-14")
        let quotaJSON = try fixture("retrieve-user-quota-summary-ultra-2026-11-14")
        let transport = ScriptedTransport { req in
            switch req.url?.path {
            case lsPrefix + "GetUserStatus":
                return jsonResponse(statusJSON)
            case lsPrefix + "GetAllCascadeTrajectories":
                // WAL 刷盘事件里没有任何轨迹变化，仍应触发被动额度检查
                return jsonResponse(#"{"trajectorySummaries":{}}"#)
            case lsPrefix + "RetrieveUserQuotaSummary":
                return jsonResponse(quotaJSON)
            default:
                return jsonResponse("{}", status: 404)
            }
        }
        var env = home.environment
        env.transport = transport

        let syncTime = AntigravityRefreshChecks.capturedAt
        let received = LockedBox<[AntigravityAccountQuota]>([])
        let recorder = TokenUsageRecorder(
            environment: env,
            ledgerURL: home.url.appendingPathComponent("ledger.sqlite"),
            latency: 0.05,
            antigravityDebounce: 0.05,
            now: { syncTime },
            attribute: { _ in },
            onAntigravityPassiveQuota: { quota in received.mutate { $0.append(quota) } })
        recorder.start()
        defer { recorder.stop() }
        try recorder.read { _ in }

        // 1) 未开启门控：对话目录写入零请求
        try touchConversationFile(in: home, content: "1")
        Thread.sleep(forTimeInterval: 0.2)
        try expectEqual(transport.requests.count, 0)
        try expectEqual(received.value.count, 0)

        // 2) 开启门控但空闲无对话活动：零请求
        recorder.setAntigravityWatching(enabled: true)
        Thread.sleep(forTimeInterval: 0.2)
        try expectEqual(transport.requests.count, 0)
        try expectEqual(received.value.count, 0)

        // 3) 对话目录有 FSEvents（即使 changed 轨迹为空）：发 RetrieveUserQuotaSummary，体为 {} 且不含 forceRefresh
        try touchConversationFile(in: home, content: "2")
        try expect(waitUntil { received.value.count == 1 }, "应收到一次被动额度更新")

        let quotaRequests = transport.methods(named: "RetrieveUserQuotaSummary")
        try expectEqual(quotaRequests.count, 1)
        let req = try unwrap(quotaRequests.first)
        try expectEqual(req.httpMethod, "POST")
        try expectEqual(req.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), "passive-tok")
        try expectEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        try expectEqual(req.timeoutInterval, AntigravityRefresher.quotaTimeout)
        let bodyData = try unwrap(req.httpBody)
        let bodyObj = try unwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        try expectEqual(bodyObj.isEmpty, true, "被动请求体必须为空 {}，不能含 forceRefresh")
        try expect(bodyObj["forceRefresh"] == nil, "被动请求体不得包含 forceRefresh")

        let quota = try unwrap(received.value.first)
        try expectEqual(quota.email, "ultra@example.com")
        try expectEqual(quota.tierName, "Google AI Ultra")
        try expectEqual(quota.tierId, "g1-ultra-lite-tier")
        try expectEqual(quota.fetchedAt, syncTime)
        try expectEqual(quota.groups.count, 2)
        try expectEqual(quota.groups[0].buckets[1].usage?.remainingPercent, 89)
    }

    static func passiveCooldownAndReset() throws {
        let home = try TempHome()
        defer { home.remove() }
        home.antigravityProcesses.run(pid: 802, startedAt: 100, token: "cool-tok", ports: [45002])

        let statusJSON = try fixture("get-user-status-ultra-2026-11-14")
        let quotaJSON = try fixture("retrieve-user-quota-summary-ultra-2026-11-14")
        let signedIn = LockedBox(true)
        let quotaReply = LockedBox<UsageHTTPResponse>(jsonResponse(quotaJSON))

        let transport = ScriptedTransport { req in
            switch req.url?.path {
            case lsPrefix + "GetUserStatus":
                return signedIn.value ? jsonResponse(statusJSON) : jsonResponse(#"{"userStatus":{"email":""}}"#)
            case lsPrefix + "GetAllCascadeTrajectories":
                return jsonResponse(#"{"trajectorySummaries":{}}"#)
            case lsPrefix + "RetrieveUserQuotaSummary":
                return quotaReply.value
            default:
                return jsonResponse("{}", status: 404)
            }
        }
        var env = home.environment
        env.transport = transport

        let base = AntigravityRefreshChecks.capturedAt
        let clock = LockedBox(base)
        let received = LockedBox<[AntigravityAccountQuota]>([])
        let recorder = TokenUsageRecorder(
            environment: env,
            ledgerURL: home.url.appendingPathComponent("ledger.sqlite"),
            latency: 0.05,
            antigravityDebounce: 0.05,
            now: { clock.value },
            attribute: { _ in },
            onAntigravityPassiveQuota: { quota in received.mutate { $0.append(quota) } })
        recorder.setAntigravityWatching(enabled: true)
        defer { recorder.stop() }

        // t = 0s: 首次触发 -> 发 1 次 RetrieveUserQuotaSummary，成功
        try touchConversationFile(in: home, content: "t0")
        try expect(waitUntil { received.value.count == 1 }, "首次触发应回调被动额度")
        try recorder.read { _ in }
        try expectEqual(transport.methods(named: "RetrieveUserQuotaSummary").count, 1)

        // t = 179.9s: 冷却期内 -> 同步跑了 GetAllCascadeTrajectories，但不发 RetrieveUserQuotaSummary
        clock.value = base.addingTimeInterval(179.9)
        try touchConversationFile(in: home, content: "t179")
        try expect(waitUntil { transport.methods(named: "GetAllCascadeTrajectories").count == 2 }, "t179 应执行同步")
        try recorder.read { _ in }
        try expectEqual(transport.methods(named: "RetrieveUserQuotaSummary").count, 1)

        // t = 180s: 满 180s 且返回 HTTP 500 -> 发起前已推进冷却时间戳，不重扫进程、不回调
        clock.value = base.addingTimeInterval(180)
        quotaReply.value = jsonResponse("boom", status: 500)
        try touchConversationFile(in: home, content: "t180")
        try expect(waitUntil { transport.methods(named: "RetrieveUserQuotaSummary").count == 2 }, "满 180s 应再次请求")
        try recorder.read { _ in }
        try expectEqual(received.value.count, 1)
        try expectEqual(home.antigravityProcesses.listCalls, 1, "RetrieveUserQuotaSummary 失败不得清空进程句柄缓存")

        // t = 240s（距 500 失败仅 60s）: 处于失败后的 180s 冷却期内，不重试风暴
        clock.value = base.addingTimeInterval(240)
        quotaReply.value = jsonResponse(quotaJSON)
        try touchConversationFile(in: home, content: "t240")
        try expect(waitUntil { transport.methods(named: "GetAllCascadeTrajectories").count == 4 }, "t240 应执行同步")
        try recorder.read { _ in }
        try expectEqual(transport.methods(named: "RetrieveUserQuotaSummary").count, 2)

        // t = 360s（距 500 失败满 180s）: 再次尝试但返回不可识别 JSON -> 同样进入 180s 冷却
        clock.value = base.addingTimeInterval(360)
        quotaReply.value = jsonResponse("not json", status: 200)
        try touchConversationFile(in: home, content: "t360")
        try expect(waitUntil { transport.methods(named: "RetrieveUserQuotaSummary").count == 3 }, "t360 满 180s 应再次尝试")
        try recorder.read { _ in }
        try expectEqual(received.value.count, 1)

        // t = 400s: 不可识别响应后的冷却期内，跳过
        clock.value = base.addingTimeInterval(400)
        quotaReply.value = jsonResponse(quotaJSON)
        try touchConversationFile(in: home, content: "t400")
        try expect(waitUntil { transport.methods(named: "GetAllCascadeTrajectories").count == 6 }, "t400 应执行同步")
        try recorder.read { _ in }
        try expectEqual(transport.methods(named: "RetrieveUserQuotaSummary").count, 3)

        // 关闭并重新开启监听：重置冷却时间戳，立即可再次获取
        recorder.setAntigravityWatching(enabled: false)
        recorder.setAntigravityWatching(enabled: true)
        clock.value = base.addingTimeInterval(405)
        try touchConversationFile(in: home, content: "re-enabled")
        try expect(waitUntil { received.value.count == 2 }, "重开监听应重置冷却并立即抓到额度")
        try recorder.read { _ in }
        try expectEqual(transport.methods(named: "RetrieveUserQuotaSummary").count, 4)

        // 未登录时不发 RetrieveUserQuotaSummary 且不消耗冷却；登录后立即发送
        clock.value = base.addingTimeInterval(600)
        signedIn.value = false
        try touchConversationFile(in: home, content: "signed-out")
        try expect(waitUntil { transport.methods(named: "GetAllCascadeTrajectories").count == 8 }, "未登录时应完成同步")
        try recorder.read { _ in }
        try expectEqual(transport.methods(named: "RetrieveUserQuotaSummary").count, 4)

        clock.value = base.addingTimeInterval(601)
        signedIn.value = true
        try touchConversationFile(in: home, content: "signed-in-again")
        try expect(waitUntil { received.value.count == 3 }, "恢复登录后应立即请求且未被未登录同步消耗冷却")
        try recorder.read { _ in }
        try expectEqual(transport.methods(named: "RetrieveUserQuotaSummary").count, 5)
    }

    static func passiveSilentIgnoreAndManualRegression() throws {
        let home = try TempHome()
        defer { home.remove() }
        home.antigravityProcesses.run(pid: 803, startedAt: 100, token: "reg-tok", ports: [45003])

        let statusJSON = try fixture("get-user-status-ultra-2026-11-14")
        let signedIn = LockedBox(true)
        let quotaMode = LockedBox<Result<UsageHTTPResponse, URLError>>(.success(jsonResponse("bad", status: 502)))

        let transport = ScriptedTransport { req in
            switch req.url?.path {
            case lsPrefix + "GetUserStatus":
                return signedIn.value ? jsonResponse(statusJSON) : jsonResponse(#"{"userStatus":{}}"#)
            case lsPrefix + "GetAllCascadeTrajectories":
                return jsonResponse(#"{"trajectorySummaries":{}}"#)
            case lsPrefix + "RetrieveUserQuotaSummary":
                return try quotaMode.value.get()
            default:
                return jsonResponse("{}", status: 404)
            }
        }
        var env = home.environment
        env.transport = transport

        let ultra = AntigravityBoardChecks.ultra
        let pro = AntigravityBoardChecks.pro
        var board = AntigravityBoardChecks.added(ultra, pro)
        board.record(.success(AntigravityBoardChecks.ultraQuota(gemini5h: 77, fetchedAt: now)), clicked: nil)
        let boardBefore = board

        let badReplies: [(Bool, Result<UsageHTTPResponse, URLError>)] = [
            (true, .success(jsonResponse("error", status: 500))),
            (true, .failure(URLError(.timedOut))),
            (true, .success(jsonResponse("not json", status: 200))),
            (true, .success(jsonResponse(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"x","window":"daily","remainingFraction":0.5}]}]}}"#))),
            (false, .success(jsonResponse("{}"))),
        ]

        let passiveReceived = LockedBox<[AntigravityAccountQuota]>([])
        let base = AntigravityRefreshChecks.capturedAt
        let clock = LockedBox(base)
        let recorder = TokenUsageRecorder(
            environment: env,
            ledgerURL: home.url.appendingPathComponent("ledger.sqlite"),
            latency: 0.05,
            antigravityDebounce: 0.05,
            now: { clock.value },
            attribute: { _ in },
            onAntigravityPassiveQuota: { quota in
                passiveReceived.mutate { $0.append(quota) }
            })
        defer { recorder.stop() }

        for (index, item) in badReplies.enumerated() {
            signedIn.value = item.0
            quotaMode.value = item.1
            // 每次通过开关重置冷却来验证各类异常响应
            recorder.setAntigravityWatching(enabled: false)
            recorder.setAntigravityWatching(enabled: true)
            clock.value = base.addingTimeInterval(Double(index + 1) * 10)
            let expectedTrajCalls = transport.methods(named: "GetAllCascadeTrajectories").count + 1
            try touchConversationFile(in: home, content: "bad-\(index)")
            try expect(waitUntil { transport.methods(named: "GetAllCascadeTrajectories").count == expectedTrajCalls },
                       "异常用例 \(index) 应触发同步")
            try recorder.read { _ in }
        }
        for quota in passiveReceived.value {
            board.recordPassive(quota)
        }

        // 所有被动异常：零回调、看板快照与错误状态完全保留不变
        try expectEqual(passiveReceived.value.count, 0)
        try expectEqual(board, boardBefore)
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.problem), [nil, nil])
        try expectEqual(board.cards(now: at(minutes: 1))[0].groups[0].buckets[0].reading, .remaining(77, tint: .green))

        // 手动刷新回归：仍发送 {"forceRefresh": true}，并正常报告 HTTP 错误、格式不可识别与 .discarded
        signedIn.value = true
        quotaMode.value = .success(jsonResponse("nope", status: 500))
        let refresher = AntigravityRefresher(environment: env)
        let httpErr = refresher.refresh(now: base)
        try expectEqual(httpErr, .failed(email: ultra, reason: .httpStatus(500)))
        let manualReq = try unwrap(transport.methods(named: "RetrieveUserQuotaSummary").last)
        let manualBody = try unwrap(try JSONSerialization.jsonObject(with: unwrap(manualReq.httpBody)) as? [String: Any])
        try expectEqual(manualBody["forceRefresh"] as? Bool, true, "手动刷新必须继续携带 forceRefresh: true")

        let errEffect = board.record(httpErr, clicked: ultra)
        try expectEqual(errEffect, AntigravityRecordEffect(notices: [], needsSave: false))
        try expectEqual(board.cards(now: at(minutes: 1))[0].problem, .failed(.httpStatus(500)))

        quotaMode.value = .success(jsonResponse(#"{"response":{"groups":[]}}"#, status: 200))
        let badFmt = refresher.refresh(now: base)
        try expectEqual(badFmt, .unrecognizedFormat(email: ultra))
        let fmtEffect = board.record(badFmt, clicked: pro)
        try expectEqual(fmtEffect, AntigravityRecordEffect(
            notices: [AntigravityNotice(card: pro, kind: .signedInAs(ultra))],
            needsSave: true))
        try expectEqual(board.cards(now: at(minutes: 1))[0].problem, .unrecognizedFormat)
        try expectEqual(board.cards(now: at(minutes: 1))[0].groups, [], "手动格式无法识别应照常丢弃快照 (.discarded)")
    }
}
