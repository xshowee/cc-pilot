// Token 用量账本的 Antigravity 桌面端扩展（antigravity-usage ticket 02）。
// 设计约束：
// - 不改动 enum Tool，不升级 SQLite PRAGMA user_version（保持 5），通过 CREATE TABLE IF NOT EXISTS 懒建 antigravity_sessions
// - messages.tool 写入字面量 'antigravity'，cache_write 恒为 0，message_id = "antigravity:<cascadeId>:<stepIndex>" 幂等去重
// - 会话归属一旦在 antigravity_sessions 绑定账号即不再因切号改变，历史步骤绝不重归属或篡改；
//   早于 listenerStartedAt - 30s 或离线未绑定的步骤记为未归属（attribution = 2）且不触发绑定

import Foundation

extension TokenLedger {
    private static let antigravityToolName = "antigravity"

    /// 将提取并已归一化模型的 Antigravity 轨迹批次增量写入账本，返回新入账行数。
    @discardableResult
    func ingest(antigravity batches: [AntigravityExtractedBatch],
                onlineEmail: String?,
                listenerStartedAt: Date) throws -> Int {
        guard batches.contains(where: { !$0.steps.isEmpty }) else { return 0 }

        let onlineAccount = UsageAccount.antigravity(email: onlineEmail)?.id
        let cutoff = listenerStartedAt.addingTimeInterval(-30)
        // 根会话先于子代理处理，确保同批次能按统一边界建立会话归属
        let orderedBatches = batches.sorted { ($0.parentSessionID != nil ? 1 : 0) < ($1.parentSessionID != nil ? 1 : 0) }

        let added = try db.transaction { () -> Int in
            try db.execute("""
                CREATE TABLE IF NOT EXISTS antigravity_sessions (
                    session_id TEXT PRIMARY KEY,
                    account TEXT NOT NULL,
                    parent_session_id TEXT
                ) WITHOUT ROWID
                """)
            let lookupSession = try db.prepare("""
                SELECT account, parent_session_id FROM antigravity_sessions WHERE session_id = ?1
                """)
            let bindSession = try db.prepare("""
                INSERT OR IGNORE INTO antigravity_sessions (session_id, account, parent_session_id)
                VALUES (?1, ?2, ?3)
                """)
            let insertMessage = try db.prepare("""
                INSERT OR IGNORE INTO messages
                    (message_id, ts, session_id, parent_session_id, model,
                     input, output, cache_write, cache_read,
                     attribution, profile, account, tool)
                SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, '\(Self.antigravityToolName)'
                WHERE NOT EXISTS (SELECT 1 FROM rolled_message_ids WHERE message_id = ?1)
                  AND ?2 >= coalesce((SELECT value FROM meta WHERE key = 'forgotten_before'), 0)
                """)

            func storedSession(_ id: String) throws -> (account: String, parentID: String?)? {
                try lookupSession.bind([.text(id)])
                defer { _ = try? lookupSession.bind([]) }
                guard try lookupSession.step(), let account = lookupSession.text(0) else { return nil }
                return (account, lookupSession.text(1))
            }

            var newlyBoundRoots: [String: String] = [:]
            var totalAdded = 0

            for batch in orderedBatches where !batch.steps.isEmpty {
                let sessionID = batch.sessionID.lowercased()
                let storedSelf = try storedSession(sessionID)
                let initialRoot = (batch.rootSessionID ?? batch.parentSessionID ?? storedSelf?.parentID ?? sessionID).lowercased()
                let storedRoot = initialRoot == sessionID ? storedSelf : try storedSession(initialRoot)
                let preExistingAccount = storedRoot?.account ?? storedSelf?.account
                let effectiveParentID: String? = initialRoot != sessionID ? initialRoot : nil

                if let preExistingAccount, storedSelf == nil, initialRoot != sessionID {
                    try bindSession.run([.text(sessionID), .text(preExistingAccount), .text(initialRoot)])
                }

                let orderedSteps = batch.steps.sorted {
                    ($0.completedAt, $0.stepIndex) < ($1.completedAt, $1.stepIndex)
                }

                for step in orderedSteps {
                    let attribution: (state: Int, profile: SQLiteValue, account: SQLiteValue)
                    if let preExistingAccount {
                        attribution = (Self.attributedState, .text(""), .text(preExistingAccount))
                    } else if step.completedAt < cutoff {
                        attribution = (Self.unattributedState, .null, .null)
                    } else if let bound = newlyBoundRoots[initialRoot] ?? onlineAccount {
                        if newlyBoundRoots[initialRoot] == nil {
                            newlyBoundRoots[initialRoot] = bound
                            try bindSession.run([.text(initialRoot), .text(bound), .null])
                        }
                        if initialRoot != sessionID {
                            try bindSession.run([.text(sessionID), .text(bound), .text(initialRoot)])
                        }
                        attribution = (Self.attributedState, .text(""), .text(bound))
                    } else {
                        attribution = (Self.unattributedState, .null, .null)
                    }

                    try insertMessage.run([
                        .text(step.messageID),
                        .real(step.completedAt.timeIntervalSince1970),
                        .text(step.sessionID),
                        .text(effectiveParentID),
                        .text(step.model),
                        .int(step.tokens.input),
                        .int(step.tokens.output),
                        .int(0),
                        .int(step.tokens.cacheRead),
                        .int(attribution.state),
                        attribution.profile,
                        attribution.account,
                    ])
                    totalAdded += db.changes
                }
            }

            return totalAdded
        }

        if added > 0 { revision += 1 }
        return added
    }
}
