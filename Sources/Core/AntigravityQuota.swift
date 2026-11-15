// 一次 Antigravity 刷新的结果（AntigravityRefresher 给出，AntigravityBoard 并入，ticket 02）。只用于显示，不含任何凭据：
// csrf token 不出现在这里的任何类型里，失败原因也只是枚举，不带错误描述或响应原文。
//
// 额度按接口返回的顺序原样保留：组的个数、组内桶的个数都不写死（Pro 可能多于两组、组内多于两个桶、
// 只有一个周窗口，同一组里可能有两个同类窗口），每个桶带 bucketId、displayName 供界面区分。
// 每个桶的数字是 UsageWindow（已用百分比 = 100 − 剩余百分比），窗口怎么显示（剩余、已重置、变灰、颜色）
// 交给 UsageReading(window, fetchedAt:, now:)。

import Foundation

enum AntigravityRefreshResult: Equatable, Sendable {
    /// 找不到运行中的 language server：不发任何请求，不算失败
    case appNotRunning
    /// GetUserStatus 没有 email：App 里没有登录
    case notSignedIn
    /// 刷新失败。已经拿到邮箱后才失败时带上邮箱
    case failed(email: String?, reason: AntigravityRefreshFailure)
    /// 响应格式无法识别（"接口可能已变化"）。已经拿到邮箱时带上邮箱
    case unrecognizedFormat(email: String?)
    case success(AntigravityAccountQuota)

    /// 这次读到的邮箱（没读到时为 nil）
    var email: String? {
        switch self {
        case .appNotRunning, .notSignedIn: return nil
        case .failed(let email, _), .unrecognizedFormat(let email): return email
        case .success(let quota): return quota.email
        }
    }
}

enum AntigravityRefreshFailure: Equatable, Sendable {
    /// 找到了进程，但读不出它启动参数里的 csrf token
    case processUnreadable
    /// 找到了进程，但没有一个端口的 GetUserStatus 返回 200（都连不上、非 200）
    case noReachablePort
    /// RetrieveUserQuotaSummary 网络失败、超时
    case networkFailure
    /// RetrieveUserQuotaSummary 返回非 200
    case httpStatus(Int)
}

/// 当前登录账号的邮箱、套餐和各组额度
struct AntigravityAccountQuota: Equatable, Sendable {
    let email: String
    /// 套餐：userTier.name（如 "Google AI Ultra"），没有时为 nil
    let tierName: String?
    /// 套餐 id：userTier.id（如 "g1-ultra-lite-tier"），没有时为 nil
    let tierId: String?
    /// 按接口顺序的组
    let groups: [AntigravityQuotaGroup]
    /// 这次数据的读取时间
    let fetchedAt: Date
}

struct AntigravityQuotaGroup: Equatable, Sendable {
    /// 组的类别：认识的组由界面显示本地化的名字，其余照搬 displayName。
    /// 原始值是本机快照文件里的写法（AntigravityBoardStore），不能改
    enum Kind: String, Codable, Equatable, Sendable {
        /// "Gemini Models"：界面显示"Gemini 模型"
        case gemini
        /// "Claude and GPT models"：界面显示"Claude 和 GPT 模型"
        case thirdParty
        /// 其他组（如 Pro 的 "Gemini 4 Argon"）：照搬 displayName
        case other
    }

    let kind: Kind
    /// 接口原名
    let displayName: String
    /// 组内模型（description 去掉 "Models within this group:" 后按逗号分开）；前缀对不上时是整段 description，
    /// 没有 description 时为空
    let models: [String]
    /// 按接口顺序的桶
    let buckets: [AntigravityQuotaBucket]
}

struct AntigravityQuotaBucket: Equatable, Sendable {
    /// 原始值是接口 window 字段的值（AntigravityRefresher 据此解析），也是本机快照文件里的写法
    /// （AntigravityBoardStore）
    enum Window: String, Codable, Equatable, Sendable {
        case fiveHour = "5h"
        case weekly
    }

    /// 接口的 bucketId（如 "gemini-5h"），没有时为 nil
    let bucketId: String?
    /// 接口的桶名（如 "Weekly Limit Remaining"），没有时为 nil
    let displayName: String?
    let window: Window
    /// 剩余与重置时间；没有数字时（remainingFraction、resetTime 都缺等）为 nil，显示"—"
    let usage: UsageWindow?
}
