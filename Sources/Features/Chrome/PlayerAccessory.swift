import SwiftUI
import TonearmCore

/// The compact player rendered by the system tab bar accessory.
struct MiniPlayerAccessory: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    let transitionNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: 10) {
            Button { appState.showNowPlaying = true } label: {
                ArtworkView(trackRow: player.currentTrack,
                            seed: player.currentTrack?.album?.title ?? "now-playing",
                            cornerRadius: Metrics.cornerSmall)
                    .frame(width: Metrics.artworkSmall, height: Metrics.artworkSmall)
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: "now-playing", in: transitionNamespace)
            Button { appState.showNowPlaying = true } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.currentTrack?.track.title ?? "")
                        .font(Typography.headline)
                        .lineLimit(1)
                        .accessibilityIdentifier("mini.title")
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            Button { player.togglePlayPause() } label: {
                // A tap while buffering is deliberately ignored (AudioPlayer.togglePlayPause) so
                // it can't cancel a still-pending play request — show a spinner here instead of
                // the usual icon so the button doesn't look unresponsive during that window.
                if player.isStalled {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Palette.ink)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
            }
            .accessibilityLabel(player.isStalled ? "Buffering" : (player.isPlaying ? "Pause" : "Play"))
            .accessibilityValue(player.isStalled ? "Buffering" : (player.isPlaying ? "Playing" : "Paused"))
            .frame(minWidth: Metrics.minimumHitTarget, minHeight: Metrics.minimumHitTarget)
            .buttonStyle(.plain)
            .accessibilityIdentifier("mini.playpause")
            .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 56)
        .contentShape(Rectangle())
        .adaptiveGlass(cornerRadius: Metrics.glassCornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing")
        .accessibilityValue(subtitle)
        .accessibilityIdentifier("mini.player")
    }

    private var subtitle: String {
        guard let row = player.currentTrack else { return "" }
        return PlaybackDisplayPolicy.miniPlayerSubtitle(
            row: row,
            cacheState: player.cacheState,
            shuffle: player.shuffle,
            repeatMode: player.repeatMode
        )
    }
}
