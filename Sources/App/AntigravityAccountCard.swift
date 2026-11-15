// 面板里的 Antigravity 额度卡片（spec "界面"）：每个添加过的邮箱一张，样式同 KimiCard，不可点击（没有档案可切换）。
// 只按 App 核心算好的 AntigravityCard 画，不自己判断变灰、已重置或阈值。
// 布局参照 ChatGPT 档案卡片：标题是邮箱；副标题是"当前"标记（只有最后读到的账号有，CurrentBadge）和套餐标签
// （TierBadge）；最后读到的账号整张卡片用强调色底（同当前档案）。右上角是刷新按钮；删除按钮在它左边，
// 鼠标停在卡片上时才显示（点了之后面板里出现确认条）。
// 最下面一行：最后读到的账号是"N 分钟前获取"，其他账号（旧快照）是"上次读取：<时间>"，添加后还没读到过的是
// "尚未读取"（这时卡片上只有邮箱和刷新按钮）；刷新后的短暂提示
// （"打开 Antigravity 后可刷新""Antigravity 里登录的是 <邮箱>"）暂时占这一行，样式同 Kimi 复制 key 后的提示；
// 提示放不下时折行（邮箱不截断）。
// 额度按组：组标题一行，下面每个桶一行（UsageWindowLine，按看板给的顺序：5 小时窗口在前；标题见 AntigravityText）。
// 旧快照整体变灰：数字和进度条由看板给的灰色读数决定，标题也改用次要颜色。失败原因、"接口可能已变化"、
// "Antigravity 未登录"显示在最下面。
// 鼠标停在卡片上时的统计面板（ticket 05）经 isViewing / onHover 接入，同 KimiCard。

import SwiftUI

struct AntigravityAccountCard: View {
    let card: AntigravityCard
    /// 界面时钟（UsageModel.now）
    let now: Date
    let isRefreshing: Bool
    let onRefresh: () -> Void
    /// 点删除按钮（面板随后显示确认条）
    let onDelete: () -> Void
    /// 给这张卡片的短暂提示；没有时为 nil
    let notice: AntigravityNotice.Kind?
    /// 侧边面板正显示这张卡片
    var isViewing = false
    /// 鼠标进出（侧边面板跟着弹出、收起）
    var onHover: ((Bool) -> Void)? = nil

    @State private var hovering = false

    private static let cornerRadius: CGFloat = 10
    private static let buttonSize: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .padding(12)
                .accessibilityElement(children: .combine)
            HStack(spacing: 2) {
                DeleteProfileButton(profileName: card.email, blocker: nil, action: onDelete)
                    .opacity(hovering ? 1 : 0)
                UsageRefreshButton(isRefreshing: isRefreshing, waitMinutes: nil, size: Self.buttonSize,
                                   action: onRefresh)
            }
            .foregroundColor(.secondary)
            // 与头像（30pt，距顶 12pt）垂直居中
            .padding(.top, 12 + (30 - Self.buttonSize) / 2)
            .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(isViewing ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: isViewing ? 2 : 1)
        )
        .onHover {
            hovering = $0
            onHover?($0)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProfileAvatar(source: card.email, isCurrent: isCurrent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: card.email)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(card.isOldSnapshot ? Color.secondary : nil)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isCurrent || card.tierName != nil {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if isCurrent {
                                CurrentBadge()
                            }
                            if let tier = card.tierName {
                                TierBadge(name: tier)
                            }
                        }
                        .font(.caption)
                    }
                }
                .padding(.trailing, 2 * (Self.buttonSize + 2))
            }
            if !card.groups.isEmpty || card.problem != nil {
                quota
            }
            footer
                .font(.caption)
                // 提示里的邮箱不截断，放不下时折行；读取时间只占一行
                .lineLimit(notice == nil ? 1 : nil)
                .fixedSize(horizontal: false, vertical: notice != nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 最后读到的账号：App 最后一次读到时登录的就是它
    private var isCurrent: Bool { !card.isOldSnapshot }

    @ViewBuilder private var footer: some View {
        switch notice {
        case .openAppToRefresh?:
            Label("Open Antigravity to refresh.", systemImage: "info.circle")
                .foregroundColor(.secondary)
        case .signedInAs(let email)?:
            Label("Antigravity is signed in as \(email).", systemImage: "info.circle")
                .foregroundColor(.secondary)
        case nil:
            if card.isNotReadYet {
                Text("Not read yet")
                    .foregroundColor(.secondary)
            } else if let fetchedAt = card.fetchedAt {
                Text(verbatim: card.isOldSnapshot
                     ? String(localized: "Last read: \(UsageDisplay.resetTime(fetchedAt, now: now))")
                     : UsageSummaryView.fetchedText(fetchedAt, now: now))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var quota: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(card.groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: AntigravityText.groupTitle(group))
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    ForEach(Array(group.buckets.enumerated()), id: \.offset) { _, bucket in
                        UsageWindowLine(title: AntigravityText.windowTitle(bucket), reading: bucket.reading,
                                        resetsAt: bucket.resetsAt, now: now)
                    }
                }
            }
            if let problem = card.problem {
                Label {
                    Text(verbatim: AntigravityText.problem(problem, hasData: !card.groups.isEmpty))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .foregroundColor(StatusColor.orange)
            }
        }
        .font(.caption)
    }
}
