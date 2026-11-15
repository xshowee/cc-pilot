// 当前在线 Antigravity 账号活跃对话的内存态实时生成速度计算（antigravity-usage ticket 05）。
// 职责与边界：
// - 纯内存计算，绝不写入 SQLite 或磁盘（保持 PRAGMA user_version = 5 不变）
// - 仅针对 GetUserStatus 当前在线邮箱：从内存中选出属于该账号、且整组（根 + 子代理）lastModifiedAt 最晚的一条活跃根对话
// - 多账号与离线安全：排除已在 antigravity_sessions 绑定给其他邮箱的会话、仅含未归属步骤的离线会话，
//   以及尚未绑定且所有步骤都在 listenerStartedAt - 30s 之前结束的离线会话
// - 严格样本过滤：仅接受 status == DONE、非 CHECKPOINT 压缩步、具备显式结束时间且 duration >= 0.5s、
//   output >= 50、且若携带 TTFT 则必须满足 0 <= ttft <= duration + 0.01s 的步骤（越界步骤同时从最新与均值剔除）

import Foundation

struct AntigravityCascadeSnapshot: Equatable, Sendable {
    let batch: AntigravityExtractedBatch
    let lastModifiedAt: Date?
    let resolvedRootID: String

    init(batch: AntigravityExtractedBatch, lastModifiedAt: Date?, resolvedRootID: String? = nil) {
        self.batch = batch
        self.lastModifiedAt = lastModifiedAt
        let fallbackRoot = batch.rootSessionID ?? batch.parentSessionID ?? batch.sessionID
        self.resolvedRootID = (resolvedRootID ?? fallbackRoot).lowercased()
    }
}

struct AntigravityLiveSpeed: Equatable, Sendable {
    let email: String
    let latestTokPerSec: Double
    let latestTtftSec: Double?
    let sessionAvgTokPerSec: Double

    static let minDurationSec: TimeInterval = 0.5
    static let minOutputTokens = 50
    static let ttftToleranceSec: TimeInterval = 0.01
    static let cutoffGraceSec: TimeInterval = 30

    private struct ValidSample {
        let step: AntigravityTrajectoryStep
        let endAt: Date
        let duration: TimeInterval
    }

    static func compute(
        onlineEmail: String?,
        listenerStartedAt: Date,
        cascades: [AntigravityCascadeSnapshot],
        boundAccounts: [String: String] = [:],
        unattributedOnlySessions: Set<String> = []
    ) -> AntigravityLiveSpeed? {
        guard let normalizedEmail = AntigravityBoard.normalizedEmail(onlineEmail) else { return nil }
        let onlineAccount = UsageAccount.antigravity(cardEmail: normalizedEmail).id
        let cutoff = listenerStartedAt.addingTimeInterval(-cutoffGraceSec)

        // 同一 cascadeId 在同批次仅保留最后一份快照，再按归属根会话分组
        var dedupBySession: [String: AntigravityCascadeSnapshot] = [:]
        for snapshot in cascades {
            dedupBySession[snapshot.batch.sessionID.lowercased()] = snapshot
        }
        let grouped = Dictionary(grouping: dedupBySession.values, by: \.resolvedRootID)

        var bestGroup: (rootID: String, lastModifiedAt: Date, snapshots: [AntigravityCascadeSnapshot])?
        for (rootID, snapshots) in grouped {
            guard isEligibleGroup(
                rootID: rootID,
                snapshots: snapshots,
                onlineAccount: onlineAccount,
                cutoff: cutoff,
                boundAccounts: boundAccounts,
                unattributedOnlySessions: unattributedOnlySessions
            ) else { continue }

            let groupLastModifiedAt = latestTimestamp(in: snapshots)
            if let current = bestGroup {
                if (groupLastModifiedAt, rootID) > (current.lastModifiedAt, current.rootID) {
                    bestGroup = (rootID, groupLastModifiedAt, snapshots)
                }
            } else {
                bestGroup = (rootID, groupLastModifiedAt, snapshots)
            }
        }

        guard let activeGroup = bestGroup else { return nil }

        let validSamples = activeGroup.snapshots
            .flatMap(\.batch.steps)
            .compactMap(validateStep)
            .sorted {
                ($0.endAt, $0.step.sessionID, $0.step.stepIndex) < ($1.endAt, $1.step.sessionID, $1.step.stepIndex)
            }

        guard let latest = validSamples.last else { return nil }
        let totalOutput = validSamples.reduce(0) { $0 + $1.step.tokens.output }
        let totalDuration = validSamples.reduce(0.0) { $0 + $1.duration }
        guard totalDuration > 0 else { return nil }

        return AntigravityLiveSpeed(
            email: normalizedEmail,
            latestTokPerSec: Double(latest.step.tokens.output) / latest.duration,
            latestTtftSec: latest.step.timeToFirstTokenSec,
            sessionAvgTokPerSec: Double(totalOutput) / totalDuration)
    }

    private static func isEligibleGroup(
        rootID: String,
        snapshots: [AntigravityCascadeSnapshot],
        onlineAccount: String,
        cutoff: Date,
        boundAccounts: [String: String],
        unattributedOnlySessions: Set<String>
    ) -> Bool {
        let boundAccount = boundAccounts[rootID]
            ?? snapshots.lazy.compactMap { boundAccounts[$0.batch.sessionID.lowercased()] }.first
        if let boundAccount {
            return boundAccount.caseInsensitiveCompare(onlineAccount) == .orderedSame
        }
        if unattributedOnlySessions.contains(rootID)
            || snapshots.contains(where: { unattributedOnlySessions.contains($0.batch.sessionID.lowercased()) }) {
            return false
        }
        return snapshots.contains { snapshot in
            snapshot.batch.steps.contains { ($0.explicitEndAt ?? $0.completedAt) >= cutoff }
        }
    }

    private static func latestTimestamp(in snapshots: [AntigravityCascadeSnapshot]) -> Date {
        var latest = Date.distantPast
        for snapshot in snapshots {
            if let lm = snapshot.lastModifiedAt, lm > latest {
                latest = lm
            }
            for step in snapshot.batch.steps {
                let stepEnd = step.explicitEndAt ?? step.completedAt
                if stepEnd > latest {
                    latest = stepEnd
                }
            }
        }
        return latest
    }

    private static func validateStep(_ step: AntigravityTrajectoryStep) -> ValidSample? {
        guard step.isDone, !step.isCompactionStep else { return nil }
        guard step.createdAt != nil, let endAt = step.explicitEndAt, let duration = step.explicitDurationSec else {
            return nil
        }
        guard duration.isFinite, duration >= minDurationSec else { return nil }
        guard step.tokens.output >= minOutputTokens else { return nil }
        if let ttft = step.timeToFirstTokenSec {
            guard ttft.isFinite, ttft >= 0, ttft <= duration + ttftToleranceSec else { return nil }
        }
        return ValidSample(step: step, endAt: endAt, duration: duration)
    }
}
