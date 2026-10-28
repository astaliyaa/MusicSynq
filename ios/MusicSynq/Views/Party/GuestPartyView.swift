import MusicSynqKit
import SwiftUI

/** A guest's view: the host's song playing here in sync, plus who's listening. */
struct GuestPartyView: View {
    let party: Party

    @Environment(AppModel.self) private var model
    @State private var confirmingLeave = false

    private var playback: PlaybackState? { party.playback }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ConnectionBanner()

                if !party.hostConnected {
                    Label("\(party.host.displayName)'s app is reconnecting. The music keeps going in the meantime.", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .card()
                }

                VStack(spacing: 16) {
                    SyncStatusPill(status: model.guest.status, drift: model.guest.drift)

                    NowPlayingView(
                        track: playback?.track,
                        isPlaying: playback?.isPlaying == true,
                        position: { playback?.position(atServerTime: model.serverNow()) ?? 0 },
                        actions: party.allowGuestControl ? guestActions : nil
                    )

                    if !party.allowGuestControl {
                        Text("Only \(party.host.displayName) can control playback.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .card()

                if case .needsSubscription = model.guest.status {
                    subscriptionHelp
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("In this party")
                        .font(.headline)
                    HStack(spacing: 12) {
                        Avatar(user: party.host, size: 36, showsOnline: party.hostConnected)
                        VStack(alignment: .leading) {
                            Text(party.host.displayName).font(.subheadline.weight(.semibold))
                            Text("Host").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "crown.fill").foregroundStyle(.yellow)
                    }
                    ForEach(party.members) { member in
                        MemberRow(member: member)
                    }
                }
                .card()

                Button(role: .destructive) {
                    confirmingLeave = true
                } label: {
                    Text("Leave party").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .confirmationDialog("Leave the party?", isPresented: $confirmingLeave, titleVisibility: .visible) {
                    Button("Leave", role: .destructive) { Task { await model.leaveParty() } }
                } message: {
                    Text("Your music stops. You can rejoin while the party is still going.")
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("\(party.host.displayName)'s party")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Resync", systemImage: "arrow.triangle.2.circlepath") { model.guest.resync() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    /** Guests' controls go to the host's app, which plays them out for everyone. */
    private var guestActions: NowPlayingView.Actions {
        NowPlayingView.Actions(
            playPause: { model.sendControl(playback?.isPlaying == true ? .pause : .play) },
            seek: { model.sendControl(.seek, position: $0) },
            skip: { delta in
                let now = playback?.position(atServerTime: model.serverNow()) ?? 0
                model.sendControl(.seek, position: max(0, now + delta))
            },
            next: { model.sendControl(.next) },
            previous: { model.sendControl(.previous) }
        )
    }

    private var subscriptionHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Music subscription needed").font(.headline)
            Text("Listening along plays full songs through your own Apple Music account, so you need an active subscription. Once you have one, tap Resync.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Resync") { model.guest.resync() }
                .buttonStyle(.bordered)
        }
        .card()
    }
}

struct SyncStatusPill: View {
    let status: GuestPlayer.Status
    let drift: Double?

    private var color: Color {
        switch status {
        case .synced: return .green
        case .loading, .idle, .paused: return .secondary
        case .unavailable, .needsSubscription, .needsPermission, .failed: return .orange
        }
    }

    private var symbol: String {
        switch status {
        case .synced: return "checkmark.circle.fill"
        case .loading: return "arrow.down.circle"
        case .idle: return "hourglass"
        case .paused: return "pause.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(status.text)
                .lineLimit(2)
            if status == .synced, let drift {
                Text(String(format: "%+.1fs", drift))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
    }
}
