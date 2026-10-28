import MusicSynqKit
import SwiftUI

/**
 * Joining a party: type the code the host gave you, or (from a friend's
 * party) ask the host to let you in and wait for them to approve.
 */
struct JoinPartySheet: View {
    /** nil when joining by code alone. */
    let summary: PartySummary?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var codeFocused: Bool

    private var normalizedCode: String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private var waiting: Bool {
        guard let summary, let pending = model.pendingJoin else { return false }
        return pending.request.partyId == summary.id
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header

                    if waiting {
                        waitingCard
                    } else {
                        codeEntry
                        if summary != nil {
                            divider
                            Button {
                                Task { await ask() }
                            } label: {
                                Label("Ask \(summary?.host.displayName ?? "the host") to let me in", systemImage: "hand.raised.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(working)
                        }
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear { if !waiting { codeFocused = true } }
            // Approved (or joined): we're in, so close the sheet.
            .onChange(of: model.party?.id) { _, id in
                if id != nil { dismiss() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            if let summary {
                Avatar(user: summary.host, size: 64)
                Text("Join \(summary.host.displayName)'s party")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let track = summary.nowPlaying {
                    Text("Now playing: \(track.title) · \(track.artist)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                Image(systemName: "number.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Join with a code")
                    .font(.title2.bold())
            }
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 14) {
            TextField("CODE", text: $code)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($codeFocused)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onChange(of: code) { _, newValue in
                    let cleaned = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
                    if cleaned != newValue { code = cleaned }
                    error = nil
                }
                .submitLabel(.join)
                .onSubmit { Task { await join() } }
                .accessibilityLabel("Party code")

            Text("Ask the host for the 6-character code on their screen.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                Task { await join() }
            } label: {
                if working { ProgressView().tint(.white) } else { Text("Join") }
            }
            .buttonStyle(BigButtonStyle())
            .disabled(normalizedCode.count < 6 || working)
            .opacity(normalizedCode.count < 6 ? 0.6 : 1)
        }
    }

    private var divider: some View {
        HStack {
            VStack { Divider() }
            Text("or").font(.footnote).foregroundStyle(.secondary)
            VStack { Divider() }
        }
    }

    private var waitingCard: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Waiting for \(summary?.host.displayName ?? "the host") to let you in…")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("They got a notification. You'll join automatically once they say yes, and you can close this in the meantime.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel request", role: .destructive) {
                Task { await model.cancelJoinRequest() }
            }
        }
        .card()
    }

    private func join() async {
        guard normalizedCode.count == 6, !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.joinParty(summary, code: normalizedCode)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ask() async {
        guard let summary else { return }
        working = true
        defer { working = false }
        do {
            try await model.requestToJoin(summary)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
