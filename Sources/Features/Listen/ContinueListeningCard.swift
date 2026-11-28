import SwiftUI
import TonearmCore

/// The Listen tab's single resume surface. Replaces the system mini player on
/// this tab only, and names the album/playlist/queue being continued when the
/// live queue makes that knowable.
struct ContinueListeningCard: View {
    let presentation: ContinueListeningPresentation
    let onResume: () -> Void

    private var headline: LocalizedStringKey {
        switch presentation.context {
        case .album: "Continue your album"
        case .playlist: "Continue your playlist"
        case .queue: "Continue your queue"
        }
    }

    private var artistText: String {
        presentation.currentTrack.artist?.name
            ?? presentation.currentTrack.album?.artist
            ?? (presentation.currentTrack.asset?.kind == .remote
                ? PlaybackDisplayPolicy.providerName(for: presentation.currentTrack.source)
                : String(localized: "On device"))
    }

    private var progressFraction: Double? {
        guard presentation.duration > 0 else { return nil }
        return min(1, max(0, presentation.elapsed / presentation.duration))
    }

    var body: some View {
        Button(action: onResume) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(headline)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.accent)
                    if let name = presentation.context.name {
                        Text(name)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    ArtworkView(
                        trackRow: presentation.currentTrack,
                        seed: presentation.currentTrack.album?.title
                            ?? presentation.currentTrack.track.title,
                        cornerRadius: Metrics.cornerSmall)
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.currentTrack.track.title)
                            .font(Typography.headline)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(artistText)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                            .lineLimit(1)
                        Text(verbatim: presentation.progressText)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "play.fill")
                        .font(Typography.calloutStrong)
                        .foregroundStyle(Palette.accentOnFill)
                        .frame(width: 40, height: 40)
                        .background(Palette.accent, in: Circle())
                        .accessibilityHidden(true)
                }

                if let fraction = progressFraction {
                    ProgressView(value: fraction)
                        .tint(Palette.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(headline))
        .accessibilityValue(Text(verbatim: "\(presentation.currentTrack.track.title), \(presentation.progressText)"))
        .accessibilityHint(Text("Resumes Platterhead playback."))
        .accessibilityIdentifier("listen.continueListening")
        .accessibilityAddTraits(.isButton)
    }
}
