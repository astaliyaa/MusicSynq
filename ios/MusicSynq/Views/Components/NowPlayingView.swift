import MusicSynqKit
import SwiftUI
import UIKit

/**
 * Artwork, title, a scrubber and transport controls. Used by both the host
 * (driving their Music app) and guests (showing the host's state, and
 * sending controls if the host allows it).
 */
struct NowPlayingView: View {
    struct Actions {
        var playPause: () -> Void
        var seek: (Double) -> Void
        var skip: (Double) -> Void
        var next: () -> Void
        var previous: () -> Void
    }

    let track: TrackInfo?
    var artwork: UIImage? = nil
    let isPlaying: Bool
    /** Called on every frame to get the current position, so the bar moves smoothly. */
    let position: () -> Double
    /** nil hides the controls' effect (they're shown disabled). */
    let actions: Actions?

    @State private var scrubbing: Double?

    private var duration: Double { track?.duration ?? 0 }

    private var subtitle: String {
        guard let track else { return " " }
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if let album = track.album, !album.isEmpty { parts.append(album) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 20) {
            ArtworkView(url: track?.artworkURL, image: artwork, size: 260, cornerRadius: 20)
                .scaleEffect(isPlaying || track == nil ? 1 : 0.9)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isPlaying)

            VStack(spacing: 4) {
                Text(track?.title ?? "Nothing playing")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                progress(current: scrubbing ?? position())
            }

            controls
        }
    }

    private func progress(current: Double) -> some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { min(current, max(duration, 0.1)) },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(duration, 0.1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        actions?.seek(target)
                        // Hold the thumb where it was dropped until the player catches up.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scrubbing = nil }
                    }
                }
            )
            .disabled(actions == nil || duration <= 0)
            .accessibilityLabel("Position")
            .accessibilityValue("\(formatTime(current)) of \(formatTime(duration))")

            HStack {
                Text(formatTime(current))
                Spacer()
                Text("-" + formatTime(max(0, duration - current)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack {
            control("backward.end.fill", label: "Previous", size: 22) { actions?.previous() }
            Spacer()
            control("gobackward.15", label: "Back 15 seconds", size: 24) { actions?.skip(-15) }
            Spacer()
            Button {
                actions?.playPause()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Spacer()
            control("goforward.15", label: "Forward 15 seconds", size: 24) { actions?.skip(15) }
            Spacer()
            control("forward.end.fill", label: "Next", size: 22) { actions?.next() }
        }
        .padding(.horizontal, 8)
        .disabled(actions == nil || track == nil)
        .buttonStyle(.plain)
        .foregroundStyle(actions == nil ? Color.secondary : Color.primary)
    }

    private func control(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }
}
