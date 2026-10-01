import SwiftUI

/// Watch redesign §3 — the 20 pt capsule that names where the audio comes out: "iPhone" or
/// "Apple Watch · AirPods Pro". Never colour alone: the symbol and the words carry the meaning.
struct WatchTargetChip: View {
    enum Tone { case neutral, warning, failure, onArtwork }

    let systemImage: String
    let title: String
    var tone: Tone = .neutral

    var body: some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch tone {
        case .neutral, .onArtwork: .primary
        case .warning: WatchPalette.warning
        case .failure: WatchPalette.failure
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Color.white.opacity(0.12)
        case .onArtwork: Color.black.opacity(0.35)
        case .warning: WatchPalette.warning.opacity(0.18)
        case .failure: WatchPalette.failure.opacity(0.18)
        }
    }
}

/// Connection or scope state in words with a dot (§3 `StatusChip`): "iPhone connected",
/// "iPhone not nearby", "Update Platterhead on iPhone".
struct WatchStatusChip: View {
    enum Tone { case good, warning, failure }

    let title: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title).lineLimit(2).multilineTextAlignment(.center)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.16)))
        .frame(maxWidth: .infinity)
    }

    private var color: Color {
        switch tone {
        case .good: WatchPalette.success
        case .warning: WatchPalette.warning
        case .failure: WatchPalette.failure
        }
    }
}
