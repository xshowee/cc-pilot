// 点击菜单栏图标后弹出的面板：标题、档案列表、底部操作。

import SwiftUI

struct PanelView: View {
    @ObservedObject var profiles: ProfileListModel

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
                        ProfileRow(profile: profile)
                        if profile.id != profiles.profiles.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            PanelFooter()
        }
        .frame(width: 320)
        .onAppear { profiles.reload() }
    }
}
