// 菜单栏显示的两行内容（spec "刷新与界面"）：
//   上一行  当前档案的订阅等级（Max 5x、Pro 等，用户更关心套餐而不是档案名）；
//           不知道订阅等级（未登录、不在列表里等）时退回当前档案名
//   下一行  当前档案所在账号的 5 小时窗口剩余百分比；从未刷新过（没有数据）时显示"—"，
//           不能显示成 0，以免误以为额度用完了。已过重置时间时不显示旧数字（见 UsageReading）。
//           颜色与列表相同：按剩余百分比的内置阈值，数据超过 30 分钟变灰（见 UsageReading）。
//
// 带额度的摘要由 UsageBoard.menuBarSummary(currentProfile:profiles:now:) 生成。

import Foundation

struct MenuBarSummary: Equatable {
    /// 当前档案名（"default" 表示默认档案）
    var profileName: String
    /// 5 小时窗口此刻怎么显示；还没有数据时为 .unavailable
    var fiveHour: UsageReading = .unavailable
    /// 当前档案的订阅等级（凭据优先，见 Profile.displayTier）；不知道时为 nil
    var tier: SubscriptionTier? = nil

    /// 第一行的文字。tierName 是订阅等级的本地化写法（由界面传入，核心不含界面文字）。
    func titleLine(tierName: (SubscriptionTier) -> String) -> String {
        tier.map(tierName) ?? profileName
    }

    /// 第二行的文字。resetText 是"已重置"的本地化写法（由界面传入，核心不含界面文字）。
    func quotaLine(resetText: String) -> String {
        switch fiveHour {
        case .unavailable: return "—"
        case .resetPendingRefresh: return resetText
        case .remaining(let percent, _): return "\(percent)%"
        }
    }

    /// 第二行的颜色；没有数字时不着色
    var quotaTint: UsageTint {
        if case .remaining(_, let tint) = fiveHour { return tint }
        return .plain
    }
}

extension MenuBarSummary {
    /// 从当前档案记录读出档案名；额度暂时没有
    init(record: CurrentProfileRecord) {
        self.init(profileName: record.currentName())
    }
}
