// 菜单栏显示的两行内容（spec "刷新与界面"）：
//   上一行  当前档案的订阅等级（Max 5x、Pro 等，用户更关心套餐而不是档案名）；
//           不知道订阅等级（未登录、不在列表里等）时退回当前档案名
//   下一行  当前档案所在账号的 5 小时窗口剩余百分比；从未刷新过（没有数据）时显示"—"，
//           不能显示成 0，以免误以为额度用完了。已过重置时间时不显示旧数字（见 UsageReading）。
//           颜色与列表相同：按剩余百分比的内置阈值，数据超过 30 分钟变灰（见 UsageReading）。
//
// 带额度的摘要由 UsageBoard.menuBarSummary(currentProfile:profiles:now:) 生成。
// 只显示 ChatGPT 一个工具时（chatgpt-profiles ticket 11）也用这两行：上一行是 ChatGPT 的套餐（chatgptPlan），
// 不知道时同样退回档案名。两个工具都显示时改为每行一个工具，见 MenuBarContent。

import Foundation

struct MenuBarSummary: Equatable {
    /// 当前档案名（"default" 表示默认档案）
    var profileName: String
    /// 5 小时窗口此刻怎么显示；还没有数据时为 .unavailable
    var fiveHour: UsageReading = .unavailable
    /// 当前档案的订阅等级（凭据优先，见 Profile.displayTier）；不知道时为 nil
    var tier: SubscriptionTier? = nil
    /// 这两行说的是哪个工具的当前档案
    var tool: Tool = .claudeCode
    /// ChatGPT 当前档案的套餐（chatgpt_plan_type 原样，最近一次刷新响应里的优先）；Claude Code 或不知道时为 nil
    var chatgptPlan: String? = nil

    /// 第一行的文字。tierName / planName 是 Claude 订阅等级 / ChatGPT 套餐的显示写法（由界面传入，核心不含界面文字）。
    func titleLine(tierName: (SubscriptionTier) -> String, planName: (String) -> String = { $0 }) -> String {
        tier.map(tierName) ?? chatgptPlan.map(planName) ?? profileName
    }

    /// 第二行的文字。resetText 是"已重置"的本地化写法（由界面传入，核心不含界面文字）。
    func quotaLine(resetText: String) -> String {
        fiveHour.menuBarText(resetText: resetText)
    }

    /// 第二行的颜色；没有数字时不着色
    var quotaTint: UsageTint { fiveHour.menuBarTint }
}

extension UsageReading {
    /// 菜单栏上额度的写法：没有数据"—"（不能显示成 0），已过重置时间显示 resetText，否则"N%"
    func menuBarText(resetText: String) -> String {
        switch self {
        case .unavailable: return "—"
        case .resetPendingRefresh: return resetText
        case .remaining(let percent, _): return "\(percent)%"
        }
    }

    /// 菜单栏上额度的颜色；没有数字时不着色
    var menuBarTint: UsageTint {
        if case .remaining(_, let tint) = self { return tint }
        return .plain
    }
}

extension MenuBarSummary {
    /// 从当前档案记录读出档案名；额度暂时没有
    init(record: CurrentProfileRecord) {
        self.init(profileName: record.currentName())
    }
}
