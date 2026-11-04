// 面板里的"添加档案"输入框（ticket 09）：点底栏的"添加档案…"后出现在底栏上方，输入档案名。
// 输入时就检查名字（不合规、保留名、已存在），有问题直接提示，"添加"不可用，不会打开终端。
// 提交后由 ProfileActionsModel 打开终端执行 ccp add；提交或取消后收起（isPresented 置为 false）。
// 有 ChatGPT 一段时（offersChatGPT），上方多一个选择工具的分段控件，选 ChatGPT 时按 ChatGPT 档案的规则检查、
// 执行 ccp chatgpt add（chatgpt-profiles ticket 05）；没有 ChatGPT 一段时只能添加 Claude Code 档案。

import SwiftUI

struct AddProfileForm: View {
    @ObservedObject var actions: ProfileActionsModel
    @Binding var isPresented: Bool
    /// 是否可以选择添加 ChatGPT 档案（面板上有 ChatGPT 一段时）
    var offersChatGPT = false

    @State private var name = ""
    @State private var selectedTool: Tool = .claudeCode
    @FocusState private var focused: Bool

    var body: some View {
        form
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .onAppear { focused = true }
    }

    private var tool: Tool { offersChatGPT ? selectedTool : .claudeCode }
    private var problem: ProfileCommands.NewNameProblem? { actions.problem(forNewName: name, tool: tool) }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            if offersChatGPT {
                Picker(selection: $selectedTool) {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        Text(verbatim: tool.displayName).tag(tool)
                    }
                } label: {
                    Text("Tool")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack(spacing: 6) {
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)
                Button("Add", action: submit)
                    .disabled(problem != nil || actions.isOpening)
                Button("Cancel", action: cancel)
            }
            if let message = Self.message(for: problem, name: name) {
                Label { message } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(.caption)
                    .foregroundColor(StatusColor.red)
            } else {
                Text("Terminal will open so you can sign in to the new profile.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func submit() {
        guard actions.add(name, tool: tool) else { return }
        cancel()
    }

    private func cancel() {
        isPresented = false
        name = ""
        selectedTool = .claudeCode
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
