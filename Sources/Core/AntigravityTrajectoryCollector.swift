// Antigravity 桌面端（Antigravity.app）本地轨迹收集器（antigravity-usage ticket 02）。
// 职责：
// - 默认关闭；仅在显式开启后监听 <HOME>/.gemini/antigravity/conversations 的 FSEvents，绝不空转定时轮询
// - 对话目录变更经 trailing-edge 防抖后触发一次增量同步；关闭时立即销毁流、取消待执行防抖并清空缓存
// - 缓存活动进程/端口/CSRF token 句柄，稳态不重扫进程；仅传输错误或非 200 时清缓存重探
// - 用 GetUserStatus 获取在线邮箱与动态模型表，用 GetAllCascadeTrajectories + 水位线过滤未变轨迹，
//   对有变化的轨迹及关联子代理调用 GetCascadeTrajectory，跳过截断响应且不推进其水位线

import CoreServices
import Foundation

final class AntigravityTrajectoryCollector {
    private struct CachedHandle: Equatable {
        let server: AntigravityLanguageServer
        let port: Int
        let csrfToken: String
    }

    private struct Watermark: Equatable {
        let stepCount: Int?
        let lastModifiedRaw: String?

        var isMeaningful: Bool { stepCount != nil || lastModifiedRaw != nil }

        func matches(_ current: Watermark) -> Bool {
            isMeaningful && self == current
        }
    }

    private struct SummaryEntry {
        let rawID: String
        let watermark: Watermark
        let lastModifiedAt: Date?
        let parentConversationID: String?
        let rootConversationID: String?
    }

    private static let servicePath = AntigravityRefresher.servicePath
    private static let host = AntigravityRefresher.host

    private let environment: CoreEnvironment
    private let conversationsRoot: URL
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let now: () -> Date
    private let openLedger: () throws -> TokenLedger
    private let afterIngest: (TokenLedger, Int) -> Void

    private(set) var isWatching = false
    private var stream: FSEventStreamRef?
    private var pendingSync: DispatchWorkItem?
    private var listenerStartedAt: Date?
    private var handle: CachedHandle?
    private var watermarks: [String: Watermark] = [:]
    private var knownRootBySession: [String: String] = [:]

    init(environment: CoreEnvironment,
         queue: DispatchQueue,
         debounce: TimeInterval = 0.5,
         now: @escaping () -> Date = Date.init,
         openLedger: @escaping () throws -> TokenLedger,
         afterIngest: @escaping (TokenLedger, Int) -> Void) {
        self.environment = environment
        let realHome = FSEventsSupport.realPath(environment.home)
        self.conversationsRoot = realHome.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
        self.queue = queue
        self.debounce = max(0.01, debounce)
        self.now = now
        self.openLedger = openLedger
        self.afterIngest = afterIngest
    }

    deinit {
        if let s = stream { FSEventsSupport.destroy(s) }
    }

    /// 必须在 queue 上调用
    func setWatching(_ enabled: Bool) {
        guard enabled != isWatching else { return }
        if enabled {
            isWatching = true
            listenerStartedAt = now()
            stream = makeStream()
            if stream == nil {
                NSLog("CC Pilot: 无法监听 Antigravity 对话目录 %@", conversationsRoot.path)
            }
        } else {
            stop()
        }
    }

    /// 必须在 queue 上调用：立即销毁 FSEvents 流、取消未触发防抖并清空所有内存状态
    func stop() {
        isWatching = false
        pendingSync?.cancel()
        pendingSync = nil
        if let s = stream { FSEventsSupport.destroy(s) }
        stream = nil
        listenerStartedAt = nil
        handle = nil
        watermarks = [:]
        knownRootBySession = [:]
    }

    // MARK: - FSEvents & Debounce

    private func makeStream() -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let streamLatency = min(debounce * 0.4, 0.05)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, [conversationsRoot.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), streamLatency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else { return nil }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        return s
    }

    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let collector = Unmanaged<AntigravityTrajectoryCollector>.fromOpaque(info).takeUnretainedValue()
        guard collector.isWatching else { return }
        collector.scheduleDebouncedSync()
    }

    private func scheduleDebouncedSync() {
        guard isWatching else { return }
        pendingSync?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isWatching else { return }
            self.pendingSync = nil
            self.sync()
        }
        pendingSync = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    // MARK: - Sync & RPC

    private func sync() {
        guard isWatching, let startedAt = listenerStartedAt else { return }
        let hadCachedHandle = handle != nil
        guard var session = acquireUserStatusSession() else { return }
        var summariesData = callRPC("GetAllCascadeTrajectories", handle: session.handle, body: [:])
        if summariesData == nil, hadCachedHandle {
            handle = nil
            guard let refreshed = acquireUserStatusSession() else { return }
            session = refreshed
            summariesData = callRPC("GetAllCascadeTrajectories", handle: session.handle, body: [:])
        }
        guard let summariesData else {
            handle = nil
            return
        }

        let userStatus = AntigravityModelResolver.parseUserStatus(session.userStatusData)
        let summaries = parseSummaries(summariesData)
        seedKnownRoots(from: summaries)

        let changed = summaries.keys.sorted().filter { lower in
            guard let summary = summaries[lower] else { return false }
            return watermarks[lower]?.matches(summary.watermark) != true
        }
        guard !changed.isEmpty else { return }

        var pending = changed
        var visited: Set<String> = []
        var completed: [(lower: String, watermark: Watermark, batch: AntigravityExtractedBatch)] = []

        while !pending.isEmpty {
            let lower = pending.removeFirst()
            guard !visited.contains(lower) else { continue }
            visited.insert(lower)

            let summary = summaries[lower]
            let rawID = summary?.rawID ?? lower
            guard let trajectoryData = callRPC("GetCascadeTrajectory", handle: session.handle, body: ["cascadeId": rawID]) else {
                handle = nil
                break
            }

            let extraction = AntigravityModelResolver.extractSteps(
                cascadeID: rawID,
                trajectoryData: trajectoryData,
                summaryLastModifiedAt: summary?.lastModifiedAt,
                summaryParentID: summary?.parentConversationID,
                summaryRootID: summary?.rootConversationID,
                dynamicModels: userStatus.dynamicModels,
                knownRootID: knownRootBySession[lower])

            switch extraction {
            case .truncated:
                continue
            case .complete(let batch):
                recordRelations(for: batch)
                for childLower in batch.childCascadeIDs where !visited.contains(childLower) {
                    if let childSummary = summaries[childLower],
                       watermarks[childLower]?.matches(childSummary.watermark) == true {
                        continue
                    }
                    pending.append(childLower)
                }
                if let watermark = summary?.watermark {
                    completed.append((lower, watermark, batch))
                } else {
                    completed.append((lower, Watermark(stepCount: nil, lastModifiedRaw: nil), batch))
                }
            }
        }

        guard !completed.isEmpty else { return }
        let convergedBatches = completed.map { item -> AntigravityExtractedBatch in
            let root = resolveRoot(of: item.batch.sessionID)
            let parent = (root != item.batch.sessionID) ? root : nil
            return AntigravityExtractedBatch(
                sessionID: item.batch.sessionID,
                parentSessionID: parent,
                rootSessionID: root,
                childCascadeIDs: item.batch.childCascadeIDs,
                steps: item.batch.steps)
        }

        do {
            let ledger = try openLedger()
            let revisionBefore = ledger.revision
            try ledger.ingest(
                antigravity: convergedBatches,
                onlineEmail: userStatus.email,
                listenerStartedAt: startedAt)
            for item in completed where item.watermark.isMeaningful {
                watermarks[item.lower] = item.watermark
            }
            afterIngest(ledger, revisionBefore)
        } catch {
            NSLog("CC Pilot: Antigravity 账本入账失败：%@", String(describing: error))
        }
    }

    private func acquireUserStatusSession() -> (handle: CachedHandle, userStatusData: Data)? {
        if let cached = handle, let data = callRPC("GetUserStatus", handle: cached, body: [:]) {
            return (cached, data)
        }
        handle = nil
        let processes = environment.antigravityProcesses
        for server in processes.languageServers() {
            guard let token = processes.csrfToken(of: server) else { continue }
            for port in processes.listeningPorts(of: server) {
                let candidate = CachedHandle(server: server, port: port, csrfToken: token)
                if let data = callRPC("GetUserStatus", handle: candidate, body: [:]) {
                    handle = candidate
                    return (candidate, data)
                }
            }
        }
        return nil
    }

    private func callRPC(_ method: String, handle: CachedHandle, body: [String: Any]) -> Data? {
        guard let url = URL(string: "http://\(Self.host):\(handle.port)" + Self.servicePath + method) else {
            return nil
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: AntigravityRefresher.probeTimeout)
        request.httpMethod = "POST"
        request.setValue(handle.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let response = try? environment.transport.send(request), response.status == 200 else {
            return nil
        }
        return response.body
    }

    // MARK: - Summary & Hierarchy Helpers

    private func parseSummaries(_ data: Data) -> [String: SummaryEntry] {
        guard let root = AntigravityModelResolver.jsonObject(data),
              let rawMap = root["trajectorySummaries"] as? [String: Any] else {
            return [:]
        }
        var result: [String: SummaryEntry] = [:]
        for (rawID, rawValue) in rawMap {
            guard let dict = rawValue as? [String: Any],
                  let lower = AntigravityModelResolver.normalizedID(rawID) else { continue }
            let stepCount = AntigravityModelResolver.intValue(dict["stepCount"])
            let lastModifiedRaw = AntigravityModelResolver.stringValue(dict["lastModifiedTime"])
            let lastModifiedAt = AntigravityModelResolver.parseISO8601(lastModifiedRaw)
            let meta = (dict["trajectoryMetadata"] as? [String: Any])
                ?? (dict["metadata"] as? [String: Any])
                ?? dict
            let parentID = AntigravityModelResolver.normalizedID(
                AntigravityModelResolver.stringValue(meta["parentConversationId"]))
            let rootID = AntigravityModelResolver.normalizedID(
                AntigravityModelResolver.stringValue(meta["rootConversationId"]))
            result[lower] = SummaryEntry(
                rawID: rawID,
                watermark: Watermark(stepCount: stepCount, lastModifiedRaw: lastModifiedRaw),
                lastModifiedAt: lastModifiedAt,
                parentConversationID: parentID,
                rootConversationID: rootID)
        }
        return result
    }

    private func seedKnownRoots(from summaries: [String: SummaryEntry]) {
        for (lower, entry) in summaries {
            if let root = entry.rootConversationID ?? entry.parentConversationID, root != lower {
                knownRootBySession[lower] = root
            }
        }
    }

    private func recordRelations(for batch: AntigravityExtractedBatch) {
        if let parent = batch.rootSessionID ?? batch.parentSessionID, parent != batch.sessionID {
            knownRootBySession[batch.sessionID] = parent
        }
        let ownerRoot = resolveRoot(of: batch.sessionID)
        for childLower in batch.childCascadeIDs where childLower != ownerRoot {
            if knownRootBySession[childLower] == nil {
                knownRootBySession[childLower] = ownerRoot
            }
        }
    }

    private func resolveRoot(of sessionID: String) -> String {
        var current = sessionID
        var seen: Set<String> = [current]
        while let next = knownRootBySession[current], seen.insert(next).inserted {
            current = next
        }
        return current
    }
}
