// 面板里的 Kimi Code 账号卡片（ADR 0007）：样式同 ChatGPTProfileCard，但不可点击（没有档案可切换）、没有统计面板。
// 标题是账号名称，副标题说明额度来自 API key（接口不返回邮箱、套餐）。右上角是刷新按钮；删除按钮在它左边，
// 鼠标停在卡片上时才显示，同其他账号行（点了之后面板里出现确认条，KimiRemovalBanner）。
// 复制 API key 的按钮在删除按钮左边，同样悬停才显示；右键菜单里也有。复制后在副标题位置短暂显示结果
// （KimiModel.copyNotice），剪贴板一分钟后自动清空。
// 额度：5 小时窗口、周窗口（剩余百分比、重置时间、进度条）、获取时间、失败原因，显示规则复用 Claude 一侧
// （UsageWindowLine、UsageSummaryView）。周窗口不分模型，标题是"周窗口"；key 相关的失败原因用这里自己的文字
// （看板里是映射过的 LoginStatus，见 KimiUsageRefresher 文件头）——Claude 的提示会让用户去打开 claude。
// 还没刷新过时提示点刷新：添加账号不会自动请求额度。

import SwiftUI

struct KimiCard: View {
    /// 账号名称
    let name: String
    /// 这个账号的额度状态；还没刷新过时为 nil
    let usage: AccountUsage?
    /// 界面时钟（UsageModel.now）
    let now: Date
    let isRefreshing: Bool
    let onRefresh: () -> Void
    /// 点删除按钮（面板随后显示确认条）
    let onDelete: () -> Void
    /// 点复制 API key
    let onCopyKey: () -> Void
    /// 最近一次复制的结果；不是这个账号的或没有时为 nil
    let copyNotice: KimiModel.CopyNotice?

    @State private var hovering = false

    private static let cornerRadius: CGFloat = 10
    private static let buttonSize: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .padding(12)
                .accessibilityElement(children: .combine)
            HStack(spacing: 2) {
                copyButton
                    .opacity(hovering ? 1 : 0)
                DeleteProfileButton(profileName: name, blocker: nil, action: onDelete)
                    .opacity(hovering ? 1 : 0)
                UsageRefreshButton(isRefreshing: isRefreshing,
                                   waitMinutes: usage?.waitRemaining(now: now).map(UsageDisplay.waitMinutes),
                                   size: Self.buttonSize, action: onRefresh)
            }
            .foregroundColor(.secondary)
            // 与头像（30pt，距顶 12pt）垂直居中
            .padding(.top, 12 + (30 - Self.buttonSize) / 2)
            .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy API Key", action: onCopyKey)
            Divider()
            Button("Delete “\(name)”…", action: onDelete)
        }
    }

    private var copyButton: some View {
        Button(action: onCopyKey) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
        }
        .buttonStyle(.borderless)
        .help(Text("Copy API Key"))
        .accessibilityLabel(Text("Copy API Key"))
    }

    @ViewBuilder private var subtitle: some View {
        switch copyNotice?.copied {
        case true?:
            Label("Copied. The clipboard clears in 1 minute.", systemImage: "checkmark")
                .foregroundColor(.secondary)
        case false?:
            Label("Couldn’t read the API key from the keychain.", systemImage: "exclamationmark.circle")
                .foregroundColor(StatusColor.orange)
        case nil:
            Text("API key")
                .foregroundColor(.secondary)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProfileAvatar(source: name, isCurrent: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    subtitle
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.trailing, 3 * (Self.buttonSize + 2))
            }
            if let usage {
                summary(usage)
            } else {
                Text("Click refresh to fetch usage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ usage: AccountUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reading = usage.fiveHour(now: now) {
                UsageWindowLine(title: String(localized: "5-hour"), reading: reading,
                                resetsAt: usage.fiveHourWindow?.window.resetsAt, now: now)
            }
            if let reading = usage.sevenDay(now: now) {
                UsageWindowLine(title: String(localized: "Weekly"), reading: reading,
                                resetsAt: usage.sevenDayWindow?.window.resetsAt, now: now)
            }
            UsageSummaryView(usage: usage, part: .fetchedAt, now: now)
            if case .login(let status) = usage.problem {
                Label {
                    Text(verbatim: Self.keyProblemText(status))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .foregroundColor(StatusColor.orange)
            } else {
                UsageSummaryView(usage: usage, part: .problem, now: now)
            }
        }
        .font(.caption)
    }

    /// key 相关的失败原因（映射见 KimiUsageRefresher 文件头）
    private static func keyProblemText(_ status: LoginStatus) -> String {
        switch status {
        case .accountUnreadable, .incompatible:
            return String(localized: "Couldn’t read the API key from the keychain.")
        default:
            return String(localized: "Kimi rejected the API key. Delete this account and add it again with a new key.")
        }
    }
}
