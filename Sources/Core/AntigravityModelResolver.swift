// Antigravity 桌面端轨迹步骤提取与模型名归一化（antigravity-usage ticket 02）。
// 纯解析模块：
// - 从 GetUserStatus 提取在线邮箱与动态 clientModelConfigs（modelOrAlias.model -> modelId / label）
// - 从 GetCascadeTrajectory 提取已完结（CORTEX_STEP_STATUS_DONE）且非零用量的步骤，带 numTotalSteps 截断保护
// - 5 级模型优先级 + CHECKPOINT 同 provider 邻居回退推断 + 动态/responseModel/静态归一化（未知原样保留）
// - 子代理关系提取（parentConversationId / rootConversationId / invokeSubagent）

import Darwin
import Foundation

struct AntigravityDynamicModelConfig: Equatable, Sendable {
    let modelId: String?
    let label: String?
}

struct AntigravityUserStatusInfo: Equatable, Sendable {
    let email: String?
    let dynamicModels: [String: AntigravityDynamicModelConfig]
}

struct AntigravityTrajectoryStep: Equatable, Sendable {
    let messageID: String
    let sessionID: String
    let stepIndex: Int
    let completedAt: Date
    let createdAt: Date?
    let finishedAt: Date?
    let model: String
    let tokens: TokenCounts
    let isCompactionStep: Bool
    let timeToFirstTokenSec: Double?
}

struct AntigravityExtractedBatch: Equatable, Sendable {
    let sessionID: String
    let parentSessionID: String?
    let rootSessionID: String?
    let childCascadeIDs: [String]
    let steps: [AntigravityTrajectoryStep]
}

enum AntigravityTrajectoryExtractionResult: Equatable, Sendable {
    case complete(AntigravityExtractedBatch)
    case truncated
}

enum AntigravityModelResolver {
    /// 与 pricing-catalog.json 同步的静态占位符映射（入账前将 MODEL_PLACEHOLDER_* / MODEL_* 转为规范模型标识）
    static let staticPlaceholders: [String: String] = [
        "MODEL_PLACEHOLDER_M667": "gemini-pro-orchestrator",
        "MODEL_PLACEHOLDER_M681": "gemini-pro-orchestrator-argon",
        "MODEL_PLACEHOLDER_M669": "gemini-flash-worker-agy",
        "MODEL_PLACEHOLDER_M429": "gemini-4-carbon-high",
        "MODEL_PLACEHOLDER_M427": "gemini-4-carbon-high",
        "MODEL_PLACEHOLDER_M437": "gemini-4-carbon-medium",
        "MODEL_PLACEHOLDER_M438": "gemini-4-carbon-low",
        "MODEL_PLACEHOLDER_M528": "gemini-4-hydrogen-xhigh",
        "MODEL_PLACEHOLDER_M525": "gemini-4-hydrogen-high",
        "MODEL_PLACEHOLDER_M526": "gemini-4-hydrogen-medium",
        "MODEL_PLACEHOLDER_M527": "gemini-4-hydrogen-low",
        "MODEL_PLACEHOLDER_M417": "gemini-4-argon-high",
        "MODEL_PLACEHOLDER_M418": "gemini-4-argon-medium",
        "MODEL_PLACEHOLDER_M419": "gemini-4-argon-low",
        "MODEL_PLACEHOLDER_M318": "gemini-3.8-flash-high",
        "MODEL_PLACEHOLDER_M319": "gemini-3.8-flash-medium",
        "MODEL_PLACEHOLDER_M320": "gemini-3.8-flash-low",
        "MODEL_PLACEHOLDER_M322": "gemini-3.8-flash-tiered",
        "MODEL_PLACEHOLDER_M298": "gemini-3.7-flash-high",
        "MODEL_PLACEHOLDER_M299": "gemini-3.7-flash-medium",
        "MODEL_PLACEHOLDER_M300": "gemini-3.7-flash-low",
        "MODEL_PLACEHOLDER_M301": "gemini-3.7-flash-tiered",
        "MODEL_PLACEHOLDER_M71": "gemini-3.6-flash-high",
        "MODEL_PLACEHOLDER_M72": "gemini-3.6-flash-medium",
        "MODEL_PLACEHOLDER_M73": "gemini-3.6-flash-low",
        "MODEL_PLACEHOLDER_M196": "gemini-3.6-flash",
        "MODEL_PLACEHOLDER_M149": "gemini-3.5-flash-high",
        "MODEL_PLACEHOLDER_M20": "gemini-3.5-flash",
        "MODEL_PLACEHOLDER_M187": "gemini-3.5-flash-extra-low",
        "MODEL_PLACEHOLDER_M198": "gemini-3.5-flash-lite",
        "MODEL_PLACEHOLDER_M37": "gemini-3.1-pro-high",
        "MODEL_PLACEHOLDER_M36": "gemini-3.1-pro-low",
        "MODEL_PLACEHOLDER_M50": "gemini-3.1-flash-lite",
        "MODEL_PLACEHOLDER_M59": "gemini-for-google-3.1-flash",
        "MODEL_PLACEHOLDER_M21": "gemini-3.1-flash-image",
        "MODEL_PLACEHOLDER_M18": "gemini-3-flash",
        "MODEL_PLACEHOLDER_M9": "gemini-3-pro-image",
        "MODEL_GOOGLE_GEMINI_2_5_PRO": "gemini-2.5-pro",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH": "gemini-2.5-flash",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING": "gemini-2.5-flash",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE": "gemini-2.5-flash-lite",
        "MODEL_PLACEHOLDER_M406": "claude-opus-5-5-max",
        "MODEL_PLACEHOLDER_M402": "claude-opus-5-5-high",
        "MODEL_PLACEHOLDER_M401": "claude-opus-5-5-medium",
        "MODEL_PLACEHOLDER_M400": "claude-opus-5-5-low",
        "MODEL_PLACEHOLDER_M368": "claude-opus-5-5",
        "MODEL_PLACEHOLDER_M407": "claude-sonnet-5-5-max",
        "MODEL_PLACEHOLDER_M405": "claude-sonnet-5-5-high",
        "MODEL_PLACEHOLDER_M404": "claude-sonnet-5-5-medium",
        "MODEL_PLACEHOLDER_M403": "claude-sonnet-5-5-low",
        "MODEL_PLACEHOLDER_M254": "claude-opus-4-8",
        "MODEL_PLACEHOLDER_M26": "claude-opus-4-6-thinking",
        "MODEL_PLACEHOLDER_M35": "claude-sonnet-4-6",
        "MODEL_PLACEHOLDER_M12": "claude-opus-4-5-thinking",
        "MODEL_PLACEHOLDER_M11": "claude-opus-4-5",
        "MODEL_CLAUDE_4_5_SONNET_THINKING": "claude-sonnet-4-5-thinking",
        "MODEL_CLAUDE_4_5_SONNET": "claude-sonnet-4-5",
        "MODEL_OPENAI_GPT_OSS_120B_MEDIUM": "gpt-oss-120b-medium",
    ]

    /// 从 GetUserStatus JSON 提取在线邮箱与 cascadeModelConfigData.clientModelConfigs 映射表
    static func parseUserStatus(_ data: Data) -> AntigravityUserStatusInfo {
        guard let root = jsonObject(data) else {
            return AntigravityUserStatusInfo(email: nil, dynamicModels: [:])
        }
        let userStatus = (root["userStatus"] as? [String: Any]) ?? root
        let rawEmail = stringValue(userStatus["email"])
        let email = rawEmail.flatMap { $0.contains("@") ? $0 : nil }

        let configData = userStatus["cascadeModelConfigData"] as? [String: Any]
        let configs = (configData?["clientModelConfigs"] as? [[String: Any]]) ?? []
        var dynamicModels: [String: AntigravityDynamicModelConfig] = [:]
        for item in configs {
            let aliasModel = (item["modelOrAlias"] as? [String: Any])?["model"]
            guard let key = stringValue(aliasModel ?? item["model"]), !key.isEmpty else { continue }
            let modelId = stringValue(item["modelId"])
            let label = stringValue(item["label"])
            dynamicModels[key] = AntigravityDynamicModelConfig(modelId: modelId, label: label)
        }
        return AntigravityUserStatusInfo(email: email, dynamicModels: dynamicModels)
    }

    /// 从 GetCascadeTrajectory JSON 提取已完结、非零用量步骤与子代理关系
    static func extractSteps(
        cascadeID: String,
        trajectoryData: Data,
        summaryLastModifiedAt: Date?,
        summaryParentID: String?,
        summaryRootID: String?,
        dynamicModels: [String: AntigravityDynamicModelConfig],
        knownRootID: String? = nil
    ) -> AntigravityTrajectoryExtractionResult {
        guard let root = jsonObject(trajectoryData) else {
            let sessionLower = normalizedID(cascadeID) ?? cascadeID.lowercased()
            return .complete(AntigravityExtractedBatch(
                sessionID: sessionLower, parentSessionID: nil, rootSessionID: nil,
                childCascadeIDs: [], steps: []))
        }
        let trajectory = (root["trajectory"] as? [String: Any]) ?? root
        let rawSteps = (trajectory["steps"] as? [[String: Any]]) ?? []
        let numTotalSteps = intValue(trajectory["numTotalSteps"] ?? root["numTotalSteps"])
        if let numTotalSteps, numTotalSteps > rawSteps.count {
            return .truncated
        }

        let sessionLower = normalizedID(cascadeID) ?? cascadeID.lowercased()
        let meta = (trajectory["metadata"] as? [String: Any])
            ?? (trajectory["trajectoryMetadata"] as? [String: Any])
            ?? (root["trajectoryMetadata"] as? [String: Any])
            ?? (root["metadata"] as? [String: Any])
            ?? [:]
        let rawParent = normalizedID(stringValue(meta["parentConversationId"])) ?? normalizedID(summaryParentID)
        let rawRoot = normalizedID(stringValue(meta["rootConversationId"])) ?? normalizedID(summaryRootID)
        let resolvedRoot = normalizedID(knownRootID) ?? rawRoot ?? rawParent
        let parentSessionID = resolvedRoot.flatMap { $0 != sessionLower ? $0 : nil }

        let genByStep = buildGeneratorByStep(from: trajectory["generatorMetadata"] ?? root["generatorMetadata"])
        var rawCandidates: [RawStepCandidate] = []
        rawCandidates.reserveCapacity(rawSteps.count)
        var childIDs: [String] = []
        var seenChildren: Set<String> = []

        for (arrayIndex, step) in rawSteps.enumerated() {
            for cid in extractSubagentCascadeIDs(from: step) where cid != sessionLower && seenChildren.insert(cid).inserted {
                childIDs.append(cid)
            }
            if let candidate = parseRawStepCandidate(
                step: step, arrayIndex: arrayIndex, genByStep: genByStep) {
                rawCandidates.append(candidate)
            }
        }

        inferCompactionStepModels(&rawCandidates)

        var extracted: [AntigravityTrajectoryStep] = []
        for candidate in rawCandidates {
            guard candidate.isDone, candidate.totalNonCacheWrite > 0 else { continue }
            guard let completedAt = candidate.finishedAt ?? candidate.completedAt ?? candidate.createdAt ?? summaryLastModifiedAt else {
                continue
            }
            let model = normalizeModel(
                rawModelKey: candidate.modelKey,
                responseModel: candidate.responseModel,
                dynamicModels: dynamicModels)
            extracted.append(AntigravityTrajectoryStep(
                messageID: "antigravity:\(sessionLower):\(candidate.stepIndex)",
                sessionID: sessionLower,
                stepIndex: candidate.stepIndex,
                completedAt: completedAt,
                createdAt: candidate.createdAt,
                finishedAt: candidate.finishedAt,
                model: model,
                tokens: candidate.tokens,
                isCompactionStep: candidate.isCompactionStep,
                timeToFirstTokenSec: candidate.timeToFirstTokenSec))
        }

        return .complete(AntigravityExtractedBatch(
            sessionID: sessionLower,
            parentSessionID: parentSessionID,
            rootSessionID: resolvedRoot,
            childCascadeIDs: childIDs,
            steps: extracted))
    }

    /// 将 MODEL_PLACEHOLDER_* / MODEL_* 归一化为规范模型 ID；无法解析时原样保留
    static func normalizeModel(
        rawModelKey: String?,
        responseModel: String?,
        dynamicModels: [String: AntigravityDynamicModelConfig]
    ) -> String {
        let raw = cleanValidModelValue(rawModelKey)
        let resp = cleanValidModelValue(responseModel)

        guard let raw else {
            return resp ?? "unknown"
        }

        let dyn = dynamicModels[raw]
        if let dynModelId = cleanValidModelValue(dyn?.modelId),
           dynModelId != raw,
           !dynModelId.hasPrefix("MODEL_") {
            return dynModelId
        }
        guard raw.hasPrefix("MODEL_") else {
            return raw
        }
        if let resp, !resp.hasPrefix("MODEL_") {
            return resp
        }
        if let staticID = staticPlaceholders[raw] {
            return staticID
        }
        if let label = dyn?.label, let slug = slugFromLabel(label) {
            return slug
        }
        return raw
    }

    /// 解析 ISO-8601 时间（支持 1-9+ 位小数秒与 Z / ±HH:MM / ±HHMM 偏移）
    static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let parsed = parseFastISO8601(raw) {
            return parsed
        }
        return fallbackParseISO8601(raw)
    }

    // MARK: - Step & Generator Parsing

    private struct RawStepCandidate {
        let stepIndex: Int
        let isDone: Bool
        let isCompactionStep: Bool
        var modelKey: String?
        var modelIsExplicit: Bool
        var responseModel: String?
        let apiProvider: String
        let createdAt: Date?
        let completedAt: Date?
        let finishedAt: Date?
        let tokens: TokenCounts
        let timeToFirstTokenSec: Double?

        var totalNonCacheWrite: Int { tokens.input + tokens.output + tokens.cacheRead }
    }

    private static func buildGeneratorByStep(from value: Any?) -> [Int: [String: Any]] {
        guard let list = value as? [[String: Any]] else { return [:] }
        var map: [Int: [String: Any]] = [:]
        for item in list {
            guard let indices = item["stepIndices"] as? [Any] else { continue }
            for rawIndex in indices {
                if let idx = intValue(rawIndex) {
                    map[idx] = item
                }
            }
        }
        return map
    }

    private static func parseRawStepCandidate(
        step: [String: Any],
        arrayIndex: Int,
        genByStep: [Int: [String: Any]]
    ) -> RawStepCandidate? {
        guard let metadata = step["metadata"] as? [String: Any] else { return nil }
        let retryInfos = metadata["retryInfos"] as? [[String: Any]]
        let retryUsage = retryInfos?.first?["usage"] as? [String: Any]
        guard let usage = (metadata["modelUsage"] as? [String: Any]) ?? retryUsage else { return nil }

        let sourceStepInfo = metadata["sourceTrajectoryStepInfo"] as? [String: Any]
        let stepIndex = intValue(sourceStepInfo?["stepIndex"]) ?? arrayIndex

        let inlineGenList = metadata["generatorMetadata"] as? [[String: Any]]
        let inlineChatGen = inlineGenList?.first { $0["chatModel"] is [String: Any] }
        let gm = inlineChatGen ?? genByStep[stepIndex]
        let chat = gm?["chatModel"] as? [String: Any]
        let chatUsage = chat?["usage"] as? [String: Any]

        let input = max(0, intValue(usage["inputTokens"]) ?? 0)
        let output = max(0, intValue(usage["outputTokens"]) ?? 0)
        let cacheRead = max(0, intValue(usage["cacheReadTokens"]) ?? 0)

        let modelCandidates: [Any?] = [
            usage["model"],
            chatUsage?["model"],
            chat?["model"],
            metadata["generatorModel"],
            chat?["responseModel"],
        ]
        let rawModel = modelCandidates.compactMap { cleanValidModelValue(stringValue($0)) }.first
        let responseModel = [chat?["responseModel"], usage["responseModel"], metadata["responseModel"]]
            .compactMap { cleanValidModelValue(stringValue($0)) }
            .first
        let apiProvider = stringValue(usage["apiProvider"]) ?? stringValue(chatUsage?["apiProvider"]) ?? ""

        let status = stringValue(step["status"])
        let stepType = stringValue(step["type"]) ?? ""
        let isCompactionStep = stepType.uppercased().contains("CHECKPOINT") || (step["checkpoint"] is [String: Any])

        return RawStepCandidate(
            stepIndex: stepIndex,
            isDone: status == "CORTEX_STEP_STATUS_DONE",
            isCompactionStep: isCompactionStep,
            modelKey: rawModel,
            modelIsExplicit: rawModel != nil,
            responseModel: responseModel,
            apiProvider: apiProvider,
            createdAt: parseISO8601(stringValue(metadata["createdAt"])),
            completedAt: parseISO8601(stringValue(metadata["completedAt"])),
            finishedAt: parseISO8601(stringValue(metadata["finishedGeneratingAt"])),
            tokens: TokenCounts(input: input, output: output, cacheWrite: 0, cacheRead: cacheRead),
            timeToFirstTokenSec: parseDurationSeconds(chat?["timeToFirstToken"]))
    }

    private static func inferCompactionStepModels(_ steps: inout [RawStepCandidate]) {
        guard steps.count >= 2 else { return }

        func isCompatible(_ a: RawStepCandidate, _ b: RawStepCandidate) -> Bool {
            a.apiProvider.isEmpty || b.apiProvider.isEmpty || a.apiProvider == b.apiProvider
        }

        for idx in steps.indices {
            let target = steps[idx]
            guard target.isCompactionStep, target.modelKey == nil else { continue }

            let donor: RawStepCandidate? =
                (0..<idx).reversed().first(where: { steps[$0].modelIsExplicit && isCompatible(target, steps[$0]) })
                    .map { steps[$0] }
                ?? ((idx + 1)..<steps.count).first(where: { steps[$0].modelIsExplicit && isCompatible(target, steps[$0]) })
                    .map { steps[$0] }

            if let donor {
                steps[idx].modelKey = donor.modelKey
                if steps[idx].responseModel == nil {
                    steps[idx].responseModel = donor.responseModel
                }
            }
        }
    }

    private static func extractSubagentCascadeIDs(from step: [String: Any]) -> [String] {
        guard let inv = step["invokeSubagent"] as? [String: Any] else { return [] }
        let results = (inv["results"] as? [[String: Any]]) ?? []
        let subagents = (inv["subagents"] as? [[String: Any]]) ?? []
        let invFallback = normalizedID(stringValue(inv["conversationId"] ?? inv["subagentConversationId"]))

        let count = max(results.count, subagents.count, invFallback == nil ? 0 : 1)
        var ids: [String] = []
        for idx in 0..<count {
            let res = idx < results.count ? results[idx] : [:]
            let spec = idx < subagents.count ? subagents[idx] : (subagents.count == 1 ? subagents[0] : [:])
            let rawID = stringValue(
                res["conversationId"] ?? res["subagentConversationId"] ?? res["cascadeId"]
                    ?? spec["conversationId"] ?? spec["subagentConversationId"] ?? spec["cascadeId"])
                ?? ((idx == 0 || count == 1) ? invFallback : nil)
            if let cid = normalizedID(rawID) {
                ids.append(cid)
            }
        }
        return ids
    }

    // MARK: - Model Normalization Helpers

    private static func cleanValidModelValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let upper = trimmed.uppercased()
        if trimmed == "0" || upper == "UNKNOWN" || upper == "MODEL_UNSPECIFIED" || upper == "MODEL_UNKNOWN" {
            return nil
        }
        return trimmed
    }

    private static func slugFromLabel(_ label: String) -> String? {
        let lower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }
        let isClaude = lower.contains("claude")
        let normalizedDots = isClaude ? lower.replacingOccurrences(of: ".", with: "-") : lower

        var slug = ""
        var prevDash = false
        for ch in normalizedDots {
            if ch.isASCII && (ch.isLetter || ch.isNumber || (!isClaude && ch == ".")) {
                slug.append(ch)
                prevDash = false
            } else if !prevDash, !slug.isEmpty {
                slug.append("-")
                prevDash = true
            }
        }
        while slug.last == "-" || slug.last == "." { slug.removeLast() }
        guard !slug.isEmpty, ModelDisplayName.name(for: slug) != slug else { return nil }
        return slug
    }

    // MARK: - ISO-8601 & Duration Helpers

    private static func parseFastISO8601(_ s: String) -> Date? {
        // 形如 YYYY-MM-DDTHH:MM:SS(.nnnnnnnnn)?(Z|+HH:MM|-HH:MM|+HHMM|-HHMM)
        let bytes = Array(s.utf8)
        guard bytes.count >= 20 else { return nil }
        let sep = bytes[10]
        guard (sep == UInt8(ascii: "T") || sep == UInt8(ascii: " ")),
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":") else {
            return nil
        }
        guard let year = asciiDigits(bytes, 0, 4),
              let month = asciiDigits(bytes, 5, 2),
              let day = asciiDigits(bytes, 8, 2),
              let hour = asciiDigits(bytes, 11, 2),
              let minute = asciiDigits(bytes, 14, 2),
              let second = asciiDigits(bytes, 17, 2) else {
            return nil
        }

        var idx = 19
        var fractionalSec = 0.0
        if idx < bytes.count, bytes[idx] == UInt8(ascii: ".") {
            idx += 1
            let fracStart = idx
            var scale = 0.1
            while idx < bytes.count, bytes[idx] >= UInt8(ascii: "0"), bytes[idx] <= UInt8(ascii: "9") {
                if scale >= 1e-9 {
                    fractionalSec += Double(bytes[idx] - UInt8(ascii: "0")) * scale
                    scale *= 0.1
                }
                idx += 1
            }
            guard idx > fracStart else { return nil }
        }

        guard idx < bytes.count else { return nil }
        let tzOffset: Int
        if bytes[idx] == UInt8(ascii: "Z") || bytes[idx] == UInt8(ascii: "z"), idx + 1 == bytes.count {
            tzOffset = 0
        } else if bytes[idx] == UInt8(ascii: "+") || bytes[idx] == UInt8(ascii: "-") {
            let sign = bytes[idx] == UInt8(ascii: "+") ? 1 : -1
            let rem = bytes.count - (idx + 1)
            if rem == 5, bytes[idx + 3] == UInt8(ascii: ":"),
               let tzh = asciiDigits(bytes, idx + 1, 2), let tzm = asciiDigits(bytes, idx + 4, 2) {
                tzOffset = sign * (tzh * 3600 + tzm * 60)
            } else if rem == 4,
                      let tzh = asciiDigits(bytes, idx + 1, 2), let tzm = asciiDigits(bytes, idx + 3, 2) {
                tzOffset = sign * (tzh * 3600 + tzm * 60)
            } else if rem == 2, let tzh = asciiDigits(bytes, idx + 1, 2) {
                tzOffset = sign * (tzh * 3600)
            } else {
                return nil
            }
        } else {
            return nil
        }

        var tmValue = tm()
        tmValue.tm_year = Int32(year - 1900)
        tmValue.tm_mon = Int32(month - 1)
        tmValue.tm_mday = Int32(day)
        tmValue.tm_hour = Int32(hour)
        tmValue.tm_min = Int32(minute)
        tmValue.tm_sec = Int32(second)
        tmValue.tm_isdst = 0
        let epoch = timegm(&tmValue)
        return Date(timeIntervalSince1970: Double(epoch) - Double(tzOffset) + fractionalSec)
    }

    private static func asciiDigits(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start + count <= bytes.count else { return nil }
        var result = 0
        for i in start..<(start + count) {
            let b = bytes[i]
            guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else { return nil }
            result = result * 10 + Int(b - UInt8(ascii: "0"))
        }
        return result
    }

    private static let fallbackLock = NSLock()
    private static let fallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func fallbackParseISO8601(_ raw: String) -> Date? {
        fallbackLock.withLock { fallbackFormatter.date(from: raw) }
    }

    private static func parseDurationSeconds(_ value: Any?) -> Double? {
        guard let str = stringValue(value), str.hasSuffix("s") else { return nil }
        return Double(str.dropLast())
    }

    // MARK: - JSON Primitive Helpers

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func stringValue(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let num as NSNumber:
            return num.intValue
        case let str as String:
            return Int(str.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func normalizedID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}
