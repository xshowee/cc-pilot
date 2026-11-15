// Antigravity 的组名、窗口标题与问题的界面文字（App 核心只给类别，文字在这里本地化）。卡片与统计面板（ticket 05）共用。
//   组名：Gemini 一类"Gemini 模型"，第三方一类"Claude 和 GPT 模型"，其他组照搬接口原名
//   窗口：同 Kimi Code 卡片的"5 小时窗口""周窗口"；同一组里同一窗口类型重复时带上看板给的区分标签（extraLabel）
//   统计面板圆环：环内只放短窗口名（ringCaption），区分标签在环下另起一行
//   问题：接口可能已变化、未登录与各种刷新失败；网络失败、HTTP 错误沿用 Claude 一侧的文字

import Foundation

enum AntigravityText {
    static func groupTitle(_ group: AntigravityGroupDisplay) -> String {
        switch group.kind {
        case .gemini: return String(localized: "Gemini models")
        case .thirdParty: return String(localized: "Claude and GPT models")
        case .other: return group.displayName
        }
    }

    static func windowTitle(_ bucket: AntigravityBucketDisplay) -> String {
        switch (bucket.window, bucket.extraLabel) {
        case (.fiveHour, nil): return String(localized: "5-hour")
        case (.fiveHour, let label?): return String(localized: "5-hour (\(label))")
        case (.weekly, nil): return String(localized: "Weekly")
        case (.weekly, let label?): return String(localized: "Weekly (\(label))")
        }
    }

    /// 统计面板圆环中间的窗口名（同 Claude 面板的"5 小时""周"）；区分标签另起一行（QuotaRingView.label）
    static func ringCaption(_ bucket: AntigravityBucketDisplay) -> String {
        switch bucket.window {
        case .fiveHour: return String(localized: "5 hours")
        case .weekly: return String(localized: "Week")
        }
    }

    static func liveSpeed(_ speed: AntigravityLiveSpeed) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let latestText = String(format: "%.1f", locale: locale, speed.latestTokPerSec)
        let avgText = String(format: "%.1f", locale: locale, speed.sessionAvgTokPerSec)
        if let ttftSec = speed.latestTtftSec {
            let ttftText = String(format: "%.1f", locale: locale, ttftSec)
            return String(localized: "\(latestText) tok/s · TTFT \(ttftText)s · Avg \(avgText) tok/s")
        }
        return String(localized: "\(latestText) tok/s · Avg \(avgText) tok/s")
    }

    /// hasData：卡片还有快照数据（网络失败时说明显示的是上次的数据）
    static func problem(_ problem: AntigravityProblem, hasData: Bool) -> String {
        switch problem {
        case .unrecognizedFormat:
            return String(localized: "The usage API may have changed. Please update cc-pilot.")
        case .notSignedIn:
            return String(localized: "Not signed in to Antigravity.")
        case .failed(.processUnreadable):
            return String(localized: "Couldn’t read Antigravity’s process info.")
        case .failed(.noReachablePort):
            return String(localized: "Couldn’t connect to Antigravity.")
        case .failed(.networkFailure):
            return hasData
                ? String(localized: "Couldn’t reach the server. Showing the last data fetched.")
                : String(localized: "Couldn’t reach the server.")
        case .failed(.httpStatus(let code)):
            return String(localized: "The server returned an error (HTTP \(code)).")
        }
    }
}
