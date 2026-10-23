// 菜单栏上显示的内容。目前只有图标；ticket 07 在这里加上当前档案名和额度两行。

import SwiftUI

struct MenuBarLabel: View {
    var body: some View {
        Image(systemName: "person.2.circle")
            .accessibilityLabel(Text("CC Pilot"))
    }
}
