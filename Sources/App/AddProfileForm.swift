// 面板里的"添加档案"输入框（ticket 09）：点底栏的"添加档案…"后出现在底栏上方，输入档案名。
// 输入时就检查名字（不合规、保留名、已存在），有问题直接提示，"添加"不可用，不会打开终端。
// 提交后由 ProfileActionsModel 打开终端执行 ccp add；提交或取消后收起（isPresented 置为 false）。

import SwiftUI

struct AddProfileForm: View {
    @ObservedObject var actions: ProfileActionsModel
    @Binding var isPresented: Bool

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        form
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .onAppear { focused = true }
    }

    private var problem: ProfileCommands.NewNameProblem? { actions.problem(forNewName: name) }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        guard actions.add(name) else { return }
        cancel()
    }

    private func cancel() {
        isPresented = false
        name = ""
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
