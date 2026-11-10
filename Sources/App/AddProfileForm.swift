// 面板里的"添加档案"输入框（ticket 09）：点底栏的"添加档案…"后出现在底栏上方，输入档案名。
// 输入时就检查名字（不合规、保留名、已存在），有问题直接提示，"添加"不可用，不会打开终端。
// 提交后由 ProfileActionsModel 打开终端执行 ccp add；提交或取消后收起（isPresented 置为 false）。
// 上方是选择添加到哪一方的分段控件：Claude Code、ChatGPT（面板上有 ChatGPT 一段时，offersChatGPT，
// chatgpt-profiles ticket 05：按 ChatGPT 档案的规则检查、执行 ccp chatgpt add）、Kimi Code。
// 选 Kimi Code（ADR 0007）时多一个输入 API key 的 SecureField（不回显）：它只显示额度，没有登录可做，
// 不打开终端，名称和 key 直接交给 KimiModel 存进钥匙串，本视图不留副本。
// 菜单栏 App 没有"编辑"菜单，⌘V 不一定可用，所以 key 旁边有一个"粘贴"按钮直接取剪贴板里的文字。

import AppKit
import SwiftUI

struct AddProfileForm: View {
    /// 添加到哪一方。Kimi Code 不是 Tool（没有档案、不能切换），所以另列
    enum Target: Hashable {
        case tool(Tool)
        case kimi

        var title: String {
            switch self {
            case .tool(let tool): return tool.displayName
            case .kimi: return KimiSectionDivider.title
            }
        }
    }

    @ObservedObject var actions: ProfileActionsModel
    @ObservedObject var kimi: KimiModel
    @Binding var isPresented: Bool
    /// 是否可以选择添加 ChatGPT 档案（面板上有 ChatGPT 一段时）
    var offersChatGPT = false

    @State private var name = ""
    @State private var key = ""
    @State private var selected: Target = .tool(.claudeCode)
    @FocusState private var focused: Bool

    var body: some View {
        form
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .onAppear { focused = true }
    }

    private var targets: [Target] {
        [.tool(.claudeCode)] + (offersChatGPT ? [.tool(.chatgpt)] : []) + [.kimi]
    }

    private var target: Target { targets.contains(selected) ? selected : .tool(.claudeCode) }

    private var problem: ProfileCommands.NewNameProblem? {
        switch target {
        case .tool(let tool): return actions.problem(forNewName: name, tool: tool)
        case .kimi: return kimi.problem(forNewName: name)
        }
    }

    private var addDisabled: Bool {
        switch target {
        case .tool: return problem != nil || actions.isOpening
        case .kimi: return problem != nil || KimiAccountName.normalizedKey(key) == nil
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $selected) {
                ForEach(targets, id: \.self) { target in
                    Text(verbatim: target.title).tag(target)
                }
            } label: {
                Text("Tool")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: selected) { _ in kimi.addFailed = false }
            HStack(spacing: 6) {
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)
                if target != .kimi {
                    buttons
                }
            }
            if target == .kimi {
                HStack(spacing: 6) {
                    SecureField("API key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                        .onExitCommand(perform: cancel)
                    Button("Paste") {
                        if let text = NSPasteboard.general.string(forType: .string) { key = text }
                    }
                }
                HStack(spacing: 6) {
                    Spacer()
                    buttons
                }
            }
            if let message = Self.message(for: problem, name: name) {
                Label { message } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(.caption)
                    .foregroundColor(StatusColor.red)
            } else if target == .kimi, kimi.addFailed {
                Label {
                    Text("Couldn’t save the API key to the keychain.")
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.caption)
                .foregroundColor(StatusColor.red)
            } else {
                hint
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("Add", action: submit)
            .disabled(addDisabled)
        Button("Cancel", action: cancel)
    }

    private var hint: Text {
        target == .kimi
            ? Text("Create a key in the Kimi Code console. It’s stored in your keychain and only sent to Kimi when you refresh usage.")
            : Text("Terminal will open so you can sign in to the new profile.")
    }

    private func submit() {
        switch target {
        case .tool(let tool):
            guard actions.add(name, tool: tool) else { return }
        case .kimi:
            guard kimi.add(name, key: key) else { return }
        }
        cancel()
    }

    private func cancel() {
        isPresented = false
        name = ""
        key = ""
        selected = .tool(.claudeCode)
        kimi.addFailed = false
    }

    private static func message(for problem: ProfileCommands.NewNameProblem?, name: String) -> Text? {
        switch problem {
        case nil, .empty?: return nil
        case .malformed?:
            return Text("Use only letters, digits, “.”, “_” and “-”, starting with a letter or digit.")
        case .reserved?: return Text("“\(name)” is reserved and can’t be used as a profile name.")
        case .exists?: return Text("A profile named “\(name)” already exists.")
        }
    }
}
