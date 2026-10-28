import MusicSynqKit
import SwiftUI
import UIKit

/** A round avatar with someone's initials, tinted by their user ID. */
struct Avatar: View {
    let user: User
    var size: CGFloat = 40
    var showsOnline: Bool? = nil

    var body: some View {
        Text(user.initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Avatar.gradient(for: user.id), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if let online = showsOnline {
                    Circle()
                        .fill(online ? Color.green : Color.gray)
                        .frame(width: size * 0.28, height: size * 0.28)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
    }

    static func gradient(for seed: String) -> LinearGradient {
        let palette: [(Color, Color)] = [
            (.purple, .pink), (.blue, .purple), (.orange, .pink), (.teal, .blue),
            (.indigo, .cyan), (.pink, .orange), (.mint, .teal), (.red, .orange),
        ]
        let index = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count
        let pair = palette[index]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/** Album art from a URL or image, with a placeholder note. */
struct ArtworkView: View {
    var url: URL?
    var image: UIImage?
    var size: CGFloat
    var cornerRadius: CGFloat = 12

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: size > 100 ? 16 : 4, y: size > 100 ? 8 : 2)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.accentColor.opacity(0.8), .pink.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/** Little animated bars that show something is playing. */
struct EqualizerIcon: View {
    var isAnimating: Bool
    var color: Color = .accentColor

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { bar in
                    let phase = sin(t * (5 + Double(bar) * 1.7) + Double(bar))
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: isAnimating ? 5 + 7 * (phase + 1) / 2 : 4)
                }
            }
            .frame(width: 15, height: 14, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/** "3:07" */
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/** A rounded card background used across screens. */
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/** A full-width prominent button style. */
struct BigButtonStyle: ButtonStyle {
    var color: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
