import MusicSynqKit
import SwiftUI
import UIKit

/** The host's view of their party: the code to share, requests, the player, and guests. */
struct HostPartyView: View {
    let party: Party

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var confirmingEnd = false
    @State private var copied = false

    private var host: HostPlayer { model.host }

    /** "K 7 Q F 2 M", so VoiceOver reads it letter by letter. */
    private var spelledOutCode: String {
        (party.code ?? "").map { String($0) }.joined(separator: " ")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ConnectionBanner()

                codeCard

                if !party.pendingRequests.isEmpty {
                    requestsCard
                }

                if host.track == nil {
                    nothingPlaying
                } else {
                    NowPlayingView(
                        track: host.track,
                        artwork: host.artwork,
                        isPlaying: host.isPlaying,
                        position: { host.position },
                        actions: .init(
                            playPause: { host.togglePlayPause() },
                            seek: { host.seek(to: $0) },
                            skip: { host.skip(by: $0) },
                            next: { host.nextTrack() },
                            previous: { host.previousTrack() }
                        )
                    )
                    .card()

                    Button {
                        openURL(URL(string: "music://")!)
                    } label: {
                        Label("Pick songs in Apple Music", systemImage: "arrow.up.forward.app")
                    }
                    .font(.subheadline)
                }

                membersCard

                settingsCard

                Button(role: .destructive) {
                    confirmingEnd = true
                } label: {
                    Text("End party")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .confirmationDialog("End the party?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                    Button("End party for everyone", role: .destructive) { Task { await model.endParty() } }
                } message: {
                    Text("Everyone's music stops.")
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Your party")
        .refreshable { await model.refreshEverything() }
    }

    private var codeCard: some View {
        VStack(spacing: 10) {
            Text("PARTY CODE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.5)
            Text(party.code ?? "------")
                .font(.system(size: 44, weight: .heavy, design: .monospaced))
                .tracking(6)
                .textSelection(.enabled)
                .accessibilityLabel("Party code \(spelledOutCode)")
            Text("Friends tap your party and enter this code, or ask to join and you approve them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button {
                    UIPasteboard.general.string = party.code
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                if let code = party.code {
                    ShareLink(item: "Join my MusicSynq listening party! Code: \(code)") {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var requestsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Wants to join", systemImage: "hand.raised.fill")
                .font(.headline)
            ForEach(party.pendingRequests) { request in
                HStack(spacing: 12) {
                    Avatar(user: request.user, size: 36)
                    VStack(alignment: .leading) {
                        Text(request.user.displayName).font(.subheadline.weight(.semibold))
                        Text("@\(request.user.username)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await model.answer(request, approve: false) }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Decline \(request.user.displayName)")
                    Button {
                        Task { await model.answer(request, approve: true) }
                    } label: {
                        Text("Let in")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .card()
    }

    private var nothingPlaying: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Play something in Apple Music")
                .font(.headline)
            Text("Whatever you play — a song, an album, a playlist — your friends hear it too. Pausing and skipping around in the song are synced.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                openURL(URL(string: "music://")!)
            } label: {
                Label("Open Apple Music", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(BigButtonStyle())
            if !model.music.isAuthorized {
                Button("Allow Apple Music access") {
                    Task {
                        if model.music.authorization == .denied { model.music.openSettings() } else { await model.music.requestAccess() }
                    }
                }
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var membersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(party.members.isEmpty ? "No one's here yet" : "Listening with you (\(party.members.count))")
                .font(.headline)
            if party.members.isEmpty {
                Text("Share your code with a friend to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(party.members) { member in
                MemberRow(member: member)
                    .contextMenu {
                        Button("Remove from party", systemImage: "person.fill.xmark", role: .destructive) {
                            Task { await model.remove(member) }
                        }
                    }
            }
        }
        .card()
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { party.allowGuestControl },
                set: { allow in Task { await model.setAllowGuestControl(allow) } }
            )) {
                VStack(alignment: .leading) {
                    Text("Let guests control playback")
                    Text("Guests can pause, skip, and scrub through songs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !model.keepAliveEnabled {
                Label("Background sync is off in Settings. Keep MusicSynq open, or guests stop following when you leave the app.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .card()
    }
}

struct MemberRow: View {
    let member: PartyMember

    var body: some View {
        HStack(spacing: 12) {
            Avatar(user: member.user, size: 36, showsOnline: member.connected)
            VStack(alignment: .leading) {
                Text(member.user.displayName).font(.subheadline.weight(.semibold))
                Text(member.connected ? "@\(member.user.username)" : "Reconnecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

/** Shown while the app's live connection is down. */
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.isConnected {
            Label("Reconnecting to MusicSynq…", systemImage: "wifi.exclamationmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
