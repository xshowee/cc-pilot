// ticket 19：档案行里额度信息的显示顺序。获取时间和同一账号提示放在该账号所有额度信息之后；
// 收起时只是少了按模型周窗口和超额付费，其余各项的相对顺序与展开时相同。
// 期望值是 ticket 写明的固定顺序（字面量）。

import Foundation

final class ProfileRowOrderChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("展开时：主窗口、按模型周窗口、超额付费、获取时间、失败原因、同一账号提示", expandedOrder),
            Check("收起时：主窗口、获取时间、失败原因、同一账号提示（与展开时的相对顺序一致）", collapsedOrder),
        ]
    }

    static func expandedOrder() throws {
        try expectEqual(ProfileRowPart.order(expanded: true),
                        [.mainWindows, .modelWeekly, .extraUsage, .fetchedAt, .problem, .sameAccount])
    }

    static func collapsedOrder() throws {
        try expectEqual(ProfileRowPart.order(expanded: false),
                        [.mainWindows, .fetchedAt, .problem, .sameAccount])
    }
}
