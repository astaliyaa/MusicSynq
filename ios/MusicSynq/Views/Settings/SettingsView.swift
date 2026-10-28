import MusicSynqKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var displayName = ""
    @State private var savingName = false
    @State private var confirmingSignOut = false
    @State private var deleting = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                if let user = model.user {
                    Section("Profile") {
                        LabeledContent("Username", value: "@\(user.username)")
                        HStack {
                            TextField("Display name", text: $displayName)
                                .submitLabel(.done)
                                .onSubmit { Task { await saveName() } }
                            if displayName != user.displayName && !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                                Button(savingName ? "Saving…" : "Save") { Task { await saveName() } }
                                    .disabled(savingName)
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("Status", value: model.music.statusText)
                    if !model.music.isAuthorized {
                        Button(model.music.authorization == .notDetermined ? "Connect Apple Music" : "Open Settings") {
                            Task {
                                if model.music.authorization == .notDetermined {
                                    await model.music.requestAccess()
                                } else {
                                    model.music.openSettings()
                                }
                            }
                        }
                    }
                } header: {
                    Text("Apple Music")
                } footer: {
                    Text("Hosts just need Apple Music access. Guests also need an Apple Music subscription, since songs play from their own account.")
                }

                Section {
                    Toggle("Keep syncing in the background", isOn: $model.keepAliveEnabled)
                } footer: {
                    Text("Lets the party keep going while your phone is locked or you're in another app, like Apple Music. iOS would otherwise pause MusicSynq after a few seconds. It works by playing silence alongside your music, which uses a little more battery.")
                }

                Section("Notifications") {
                    Button("Turn on notifications") { Task { await model.requestNotificationPermission() } }
                    Text("Get a ping when a friend starts a party, asks to join yours, or sends a friend request.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Server") {
                    LabeledContent("Address", value: model.serverURL.absoluteString)
                    LabeledContent("Status", value: model.isConnected ? "Connected" : "Connecting…")
                }

                Section {
                    Button("Sign out") { confirmingSignOut = true }
                    Button("Delete account", role: .destructive) { deleting = true }
                } footer: {
                    Text("MusicSynq · Your music stays in your own Apple Music account; MusicSynq only shares what's playing during a party.")
                }
            }
            .navigationTitle("Settings")
            .onAppear { displayName = model.user?.displayName ?? "" }
            .confirmationDialog("Sign out of MusicSynq?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
            }
            .sheet(isPresented: $deleting) { DeleteAccountSheet() }
        }
    }

    private func saveName() async {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != model.user?.displayName else { return }
        savingName = true
        defer { savingName = false }
        do {
            try await model.updateDisplayName(name)
        } catch {
            model.notice = AppModel.Notice(title: "Couldn't save", message: error.localizedDescription)
        }
    }
}

private struct DeleteAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This permanently deletes your account, your friends list, and any party you're hosting. It can't be undone.")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Delete my account", role: .destructive) {
                        Task {
                            working = true
                            defer { working = false }
                            do {
                                try await model.deleteAccount(password: password)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(password.isEmpty || working)
                }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
