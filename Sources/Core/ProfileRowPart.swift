// 档案行里额度相关各项的显示顺序（ticket 19）。界面（ProfileRow）按这个顺序逐项显示，没有内容的项不显示。
// 获取时间、失败原因和同一账号提示放在该账号所有额度信息之后；收起时只是少了按模型周窗口和超额付费，
// 其余各项的相对顺序与展开时相同。

import Foundation

enum ProfileRowPart: Equatable, Hashable {
    /// 5 小时窗口和"全部模型"周窗口
    case mainWindows
    /// 按模型细分的周窗口（展开后才显示）
    case modelWeekly
    /// 超额付费（展开后才显示）
    case extraUsage
    /// "刚刚获取 / N 分钟前获取"
    case fetchedAt
    /// 最近一次刷新失败的原因（与获取时间相关：例如"连不上服务器，显示的是上次获取的数据"）
    case problem
    /// "与 X 是同一账号"
    case sameAccount

    /// expanded：账号详情是否展开
    static func order(expanded: Bool) -> [ProfileRowPart] {
        let details: [ProfileRowPart] = expanded ? [.modelWeekly, .extraUsage] : []
        return [.mainWindows] + details + [.fetchedAt, .problem, .sameAccount]
    }
}
