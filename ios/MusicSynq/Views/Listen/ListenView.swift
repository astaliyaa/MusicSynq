import MusicSynqKit
import SwiftUI

/** The Listen tab: your party if you're in one, otherwise start one or join a friend's. */
struct ListenView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let party = model.party {
                    if party.isHost {
                        HostPartyView(party: party)
                    } else {
                        GuestPartyView(party: party)
                    }
                } else {
                    LobbyView()
                }
            }
            .animation(.default, value: model.party?.id)
        }
    }
}

/** Not in a party: start one, see friends' parties, or join with a code. */
private struct LobbyView: View {
    @Environment(AppModel.self) private var model
    @State private var joining: JoinTarget?
    @State private var starting = false

    var body: some View {
        List {
            if !model.isConnected {
                Section {
                    Label("Connecting to MusicSynq…", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            }

            if let pending = model.pendingJoin {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text("Waiting for \(pending.host.displayName)")
                                .font(.headline)
                            Text("They'll get a notification to let you in.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { Task { await model.cancelJoinRequest() } }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Section {
                VStack(spacing: 14) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("Host a listening party")
                        .font(.title3.bold())
                    Text("Play anything in Apple Music and your friends hear the same song, at the same moment, wherever they are.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task {
                            starting = true
                            await model.startParty()
                            starting = false
                        }
                    } label: {
                        if starting { ProgressView().tint(.white) } else { Text("Start a party") }
                    }
                    .buttonStyle(BigButtonStyle())
                    .disabled(starting)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color(.secondarySystemGroupedBackground))

            Section {
                if model.friendsParties.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No friends are hosting right now.")
                        Text(model.friends.friends.isEmpty ? "Add friends in the Friends tab to see their parties here." : "Their parties show up here as soon as they start one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(model.friendsParties) { party in
                        Button {
                            joining = JoinTarget(summary: party)
                        } label: {
                            PartyRow(party: party, isPending: model.pendingJoin?.request.partyId == party.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Friends' parties")
            }

            Section {
                Button {
                    joining = JoinTarget(summary: nil)
                } label: {
                    Label("Join with a code", systemImage: "number")
                }
            }
        }
        .navigationTitle("Listen")
        .refreshable { await model.refreshEverything() }
        .sheet(item: $joining) { target in
            JoinPartySheet(summary: target.summary)
                .presentationDetents([.medium, .large])
        }
    }
}

struct JoinTarget: Identifiable {
    let id = UUID()
    let summary: PartySummary?
}

/** One friend's party in the list. */
struct PartyRow: View {
    let party: PartySummary
    var isPending = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: party.nowPlaying?.artworkURL, size: 52, cornerRadius: 10)
                .overlay(alignment: .bottomTrailing) {
                    Avatar(user: party.host, size: 24)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 6, y: 6)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(party.host.displayName)'s party")
                    .font(.headline)
                if let track = party.nowPlaying {
                    HStack(spacing: 6) {
                        EqualizerIcon(isAnimating: party.isPlaying)
                        Text("\(track.title) · \(track.artist)")
                            .lineLimit(1)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Nothing playing yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if isPending {
                    Text("Asked")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                Label("\(party.memberCount + 1)", systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Join this party")
    }
}
