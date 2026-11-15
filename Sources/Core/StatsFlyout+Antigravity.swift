// Antigravity 卡片的统计面板显示什么（ticket 05，spec "界面"统计面板）。界面（Sources/App/AntigravityFlyoutView.swift）
// 只按这里算好的结果画。从上到下：
//   顶部     邮箱、套餐
//   圆环卡   每组一张：每个桶一个圆环（顺序同卡片：5 小时窗口在前，Ultra 即 5 小时窗口、周窗口两个；
//            只有周窗口的组一个），
//            下列组内模型。圆环标签与卡片同一套规则（同组同窗口重复时带 extraLabel，AntigravityText）
// Token 用量卡、模型卡、历史卡、清空累计复用 TokenStatsModel（按 AntigravityBoard.knownResets 与三类 TokenKind.withoutCacheWrite 展示）。
// 内容从看板的卡片（AntigravityCard）推出，所以旧快照变灰、"已重置，待刷新"的规则与卡片完全相同：
// 灰色读数的圆环是灰弧；已重置或没有数字的圆环显示"—"、不画弧、没有倒计时（同 Claude 面板的 QuotaRing）。

import Foundation

struct AntigravityFlyout: Equatable {
    struct Group: Equatable {
        /// 组名、类别、组内模型（与卡片同一份）
        let display: AntigravityGroupDisplay
        /// 每个桶一个圆环，顺序同卡片（5 小时窗口在前）
        let rings: [Ring]
    }

    struct Ring: Equatable {
        /// 窗口类型与区分标签（标签见 AntigravityText）
        let bucket: AntigravityBucketDisplay
        let ring: QuotaRing
    }

    let email: String
    /// 套餐名；没有快照、或接口没给时为 nil
    let tierName: String?
    /// 不是最后读到的邮箱（标题变灰，同卡片）
    let isOldSnapshot: Bool
    /// 没有快照数据（还没读到过、格式无法识别后）时为空
    let groups: [Group]
    /// 当前在线非旧快照且邮箱一致时的实时生成速度；旧快照、离线或邮箱不一致时为 nil
    let visibleLiveSpeed: AntigravityLiveSpeed?

    init(_ card: AntigravityCard, now: Date, liveSpeed: AntigravityLiveSpeed? = nil) {
        email = card.email
        tierName = card.tierName
        isOldSnapshot = card.isOldSnapshot
        groups = card.groups.map { group in
            Group(display: group, rings: group.buckets.map {
                Ring(bucket: $0, ring: QuotaRing.make($0.reading, resetsAt: $0.resetsAt, now: now))
            })
        }
        if !card.isOldSnapshot,
           let liveSpeed,
           liveSpeed.email.caseInsensitiveCompare(card.email) == .orderedSame {
            visibleLiveSpeed = liveSpeed
        } else {
            visibleLiveSpeed = nil
        }
    }
}

extension AntigravityBoard {
    /// 这个邮箱的统计面板；没有这张卡片（已删除）时为 nil
    func flyout(for email: String, now: Date, liveSpeed: AntigravityLiveSpeed? = nil) -> AntigravityFlyout? {
        cards(now: now).first { $0.email == email }.map {
            AntigravityFlyout($0, now: now, liveSpeed: liveSpeed)
        }
    }
}
