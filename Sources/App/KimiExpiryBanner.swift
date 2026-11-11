// 面板里编辑 Kimi Code 账号套餐有效期的编辑条（ADR 0007，数据见 App 核心 KimiExpiry.swift）：点卡片上的日历按钮
// 或右键菜单"设置有效期…"后出现在底栏上方，样式同 KimiRemovalBanner。日期照着 kimi.com 订阅页的
// "Valid until"填；已经填过时可以清除。主面板是 key 窗口，日期选择器可以直接用键盘输入。

import SwiftUI

struct KimiExpiryBanner: View {
    let name: String
    /// 已经填过的有效期；没有时为 nil
    let current: KimiExpiryDate?
    let onCancel: () -> Void
    /// 保存（nil 表示清除）
    let onSave: (KimiExpiryDate?) -> Void

    @State private var date: Date

    init(name: String, current: KimiExpiryDate?, onCancel: @escaping () -> Void,
         onSave: @escaping (KimiExpiryDate?) -> Void) {
        self.name = name
        self.current = current
        self.onCancel = onCancel
        self.onSave = onSave
        // 没填过时默认一个月后（套餐按月续）
        let calendar = Calendar.current
        _date = State(initialValue: current?.date(in: calendar)
                      ?? calendar.date(byAdding: .month, value: 1, to: calendar.startOfDay(for: Date())) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundColor(.accentColor)
                Text("Plan expiry date for “\(name)”")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                DatePicker(selection: $date, displayedComponents: .date) { Text("Valid until") }
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .controlSize(.small)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                Text("Copy it from the subscription page on kimi.com.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if current != nil {
                    Button("Remove Date") { onSave(nil) }
                        .controlSize(.small)
                }
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                Button("Save") { onSave(KimiExpiryDate(date: date, calendar: .current)) }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onExitCommand(perform: onCancel)
    }
}
