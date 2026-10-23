// 菜单栏显示的两行内容（spec "刷新与界面"）：
//   上一行  当前档案名
//   下一行  当前档案所在账号的 5 小时窗口剩余百分比；从未刷新过（没有数据）时显示"—"，
//           不能显示成 0，以免误以为额度用完了。
//
// 带额度的摘要由 UsageBoard.menuBarSummary(currentProfile:profiles:) 生成。

import Foundation

struct MenuBarSummary: Equatable {
    /// 当前档案名（"default" 表示默认档案）
    var profileName: String
    /// 5 小时窗口剩余百分比（0–100）；还没有数据时为 nil
    var fiveHourRemaining: Int?

    init(profileName: String, fiveHourRemaining: Int? = nil) {
        self.profileName = profileName
        self.fiveHourRemaining = fiveHourRemaining
    }

    /// 从当前档案记录读出档案名；额度暂时没有
    init(record: CurrentProfileRecord) {
        self.init(profileName: record.currentName())
    }

    var quotaLine: String {
        fiveHourRemaining.map { "\($0)%" } ?? "—"
    }
}
