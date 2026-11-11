// 鼠标停在 Kimi Code 卡片上时，侧边面板里的内容（ADR 0007，2026-11-11 补充；数据见 App 核心 KimiModels.swift）。
// 与 Claude、ChatGPT 的统计面板共用同一个窗口（StatsFlyoutController），样式同 StatsFlyoutView 的卡片。从上到下：
//   顶部          账号名称、"Kimi Code"
//   Base URL 卡   Anthropic 兼容、OpenAI 兼容两个地址，各带复制按钮（固定值，不用请求，没刷新过也显示）
//   模型卡        这个账号的 key 能用的模型：名称与上下文、id（可复制）、推理强度（有时才显示，默认的一档加粗）；
//                 底部是获取时间。还没刷新过时提示点刷新；获取失败时保留上一次的列表并提示
// Base URL 和模型 id 不是机密，用普通剪贴板（不用 SecretClipboard），复制后按钮短暂变成对勾。
// 面板不是 key 窗口，按钮都是无边框的（同 FlyoutSegments 的考虑）。

import AppKit
import SwiftUI

struct KimiFlyoutView: View {
    let name: String
    /// 这个账号的模型列表；还没刷新过时为 nil
    let models: KimiModelList?
    let isRefreshing: Bool
    let now: Date

    /// 刚复制的内容（按钮显示对勾）
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            FlyoutCard {
                VStack(alignment: .leading, spacing: 8) {
                    FlyoutCardTitle(title: "Base URL") { EmptyView() }
                    urlRow(String(localized: "Anthropic-compatible"), KimiEndpoints.anthropicBaseURL)
                    urlRow(String(localized: "OpenAI-compatible"), KimiEndpoints.openAIBaseURL)
                }
            }
            FlyoutCard {
                VStack(alignment: .leading, spacing: 10) {
                    FlyoutCardTitle(title: modelsTitle) { EmptyView() }
                    modelsContent
                }
            }
        }
        .padding(StatsFlyoutView.inset)
        .onChange(of: name) { _ in copied = nil }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(verbatim: KimiSectionDivider.title)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var modelsTitle: String {
        guard let count = models?.models?.count else { return String(localized: "Models") }
        return String(localized: "Models (\(count))")
    }

    @ViewBuilder private var modelsContent: some View {
        if let list = models?.models {
            if list.isEmpty {
                note(String(localized: "No models are available for this API key."))
            }
            ForEach(list, id: \.id) { model in
                modelRow(model)
            }
            if models?.lastFailed == true {
                warning(String(localized: "Couldn’t fetch the model list. Showing the last list fetched."))
            }
            if let fetchedAt = models?.fetchedAt {
                note(UsageSummaryView.fetchedText(fetchedAt, now: now))
            }
        } else if models?.lastFailed == true {
            warning(String(localized: "Couldn’t fetch the model list."))
        } else if isRefreshing {
            note(String(localized: "Fetching…"))
        } else {
            note(String(localized: "Click refresh to fetch the model list."))
        }
    }

    private func urlRow(_ label: String, _ url: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Text(verbatim: url)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                copyButton(url, help: String(localized: "Copy Base URL"))
            }
        }
    }

    private func modelRow(_ model: KimiModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: model.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let context = model.contextLength {
                    Text(verbatim: KimiModelInfo.contextText(context))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .help(Text("Context length"))
                        .fixedSize()
                }
            }
            HStack(spacing: 4) {
                Text(verbatim: model.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                copyButton(model.id, help: String(localized: "Copy Model ID"))
                Spacer(minLength: 0)
            }
            if !model.efforts.isEmpty {
                efforts(model)
            }
        }
    }

    /// "推理强度 low · high · max"，默认的一档加粗
    private func efforts(_ model: KimiModelInfo) -> some View {
        let parts = model.efforts.map { effort in
            Text(verbatim: effort).fontWeight(effort == model.defaultEffort ? .semibold : .regular)
                .foregroundColor(effort == model.defaultEffort ? .primary : .secondary)
        }
        let joined = parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: " · ").foregroundColor(.secondary) + $1 }
        return HStack(spacing: 6) {
            Text("Reasoning effort")
                .foregroundColor(.secondary)
            joined
        }
        .font(.caption)
        .help(model.defaultEffort.map { Text("Default: \($0)") } ?? Text(verbatim: ""))
        .accessibilityElement(children: .combine)
    }

    private func copyButton(_ text: String, help: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = text
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if copied == text { copied = nil }
            }
        } label: {
            Image(systemName: copied == text ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: help))
        .accessibilityLabel(Text(verbatim: help))
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.caption)
        .foregroundColor(StatusColor.orange)
    }
}
