// 点击菜单栏图标后弹出的面板：标题、档案列表（点击即切换）、菜单栏显示设置、底部操作。

import SwiftUI

struct PanelView: View {
    @ObservedObject var profiles: ProfileListModel
    @ObservedObject var current: CurrentProfileModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Profiles")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(profiles.profiles) { profile in
                        SwitchableProfileRow(profile: profile, isCurrent: profile.name == current.name) {
                            current.switchTo(profile.name)
                        }
                        if profile.id != profiles.profiles.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            MenuBarIconOnlyToggle()
            Divider()
            PanelFooter()
        }
        .frame(width: 320)
        .onAppear { profiles.reload(); current.reload() }
    }
}
