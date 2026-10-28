import MusicSynqKit
import SwiftUI

/** Sign in or create an account. */
struct AuthView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign in"
        case register = "Create account"
        var id: Self { self }
    }

    private enum Field: Hashable {
        case username, displayName, password
    }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .register
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isWorking = false
    @State private var showingServer = false
    @FocusState private var focus: Field?

    private var canSubmit: Bool {
        let nameOK = username.trimmingCharacters(in: .whitespaces).count >= 3
        let passwordOK = mode == .signIn ? !password.isEmpty : password.count >= 8
        let displayOK = mode == .signIn || !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        return nameOK && passwordOK && displayOK && !isWorking
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header

                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 12) {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focus = mode == .register ? .displayName : .password }

                        if mode == .register {
                            TextField("Display name (what friends see)", text: $displayName)
                                .textContentType(.name)
                                .focused($focus, equals: .displayName)
                                .submitLabel(.next)
                                .onSubmit { focus = .password }
                        }

                        SecureField(mode == .register ? "Password (8+ characters)" : "Password", text: $password)
                            .textContentType(mode == .register ? .newPassword : .password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { Task { await submit() } }
                    }
                    .textFieldStyle(AuthFieldStyle())

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        if isWorking {
                            ProgressView().tint(.white)
                        } else {
                            Text(mode.rawValue)
                        }
                    }
                    .buttonStyle(BigButtonStyle())
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.6)

                    Button {
                        showingServer = true
                    } label: {
                        Label("Server: \(model.serverURL.host ?? model.serverURL.absoluteString)", systemImage: "server.rack")
                            .font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .onChange(of: mode) { error = nil }
            .sheet(isPresented: $showingServer) { ServerSheet() }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 56))
                .foregroundStyle(LinearGradient(colors: [.accentColor, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(.top, 32)
            Text("MusicSynq")
                .font(.largeTitle.bold())
            Text("Listen to Apple Music together with friends, wherever they are.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let name = username.trimmingCharacters(in: .whitespaces)
            switch mode {
            case .signIn:
                try await model.signIn(username: name, password: password)
            case .register:
                try await model.register(username: name, displayName: displayName.trimmingCharacters(in: .whitespaces), password: password)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct AuthFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/** Point the app at a different MusicSynq server (for testing or self-hosting). */
struct ServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://musicsynq.example.com", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server address")
                } footer: {
                    Text("Everyone in a party must use the same server. While testing, you can use your Mac's local IP, like http://192.168.1.20:8080.")
                }
                if let status {
                    Section { Text(status).font(.footnote) }
                }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(checking || ServerSettings.parse(text) == nil)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset to default") { text = ServerSettings.defaultURL.absoluteString }
                        .font(.footnote)
                }
            }
            .onAppear { text = model.serverURL.absoluteString }
        }
    }

    private func save() async {
        guard let url = ServerSettings.parse(text) else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: url.appendingPathComponent("health"))
        request.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            model.setServerURL(url)
            dismiss()
        } catch {
            status = "Couldn't reach a MusicSynq server at \(url.absoluteString). Check the address and that the server is running."
        }
    }
}
