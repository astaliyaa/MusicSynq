import MusicSynqKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.user == nil {
                AuthView()
            } else {
                TabView(selection: $model.selectedTab) {
                    ListenView()
                        .tabItem { Label("Listen", systemImage: "headphones") }
                        .badge(model.party?.pendingRequests.count ?? 0)
                        .tag(AppModel.Tab.listen)
                    FriendsView()
                        .tabItem { Label("Friends", systemImage: "person.2.fill") }
                        .badge(model.friends.incoming.count)
                        .tag(AppModel.Tab.friends)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                        .tag(AppModel.Tab.settings)
                }
            }
        }
        .alert(
            model.notice?.title ?? "",
            isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }),
            presenting: model.notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .alert(
            "\(model.joinPrompt?.user.displayName ?? "Someone") wants to join",
            isPresented: Binding(get: { model.joinPrompt != nil }, set: { if !$0 { model.joinPrompt = nil } }),
            presenting: model.joinPrompt
        ) { request in
            Button("Let them in") { Task { await model.answer(request, approve: true) } }
            Button("Decline", role: .destructive) { Task { await model.answer(request, approve: false) } }
            Button("Later", role: .cancel) {}
        } message: { request in
            Text("@\(request.user.username) asked to listen along to your party.")
        }
    }
}
