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
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityValue(player.isPlaying ? "Playing" : "Paused")
            .frame(minWidth: Metrics.minimumHitTarget, minHeight: Metrics.minimumHitTarget)
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .adaptiveGlass(cornerRadius: Metrics.glassCornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing")
        .accessibilityValue(subtitle)
        .accessibilityIdentifier("mini.player")
    }

    private var subtitle: String {
        if let plan = player.transitionPlan {
            let countdown = max(0, plan.exitTime - player.currentTime)
            let playback = player.currentTrack.map {
                PlaybackDisplayPolicy.miniPlayerSubtitle(row: $0, cacheState: player.cacheState,
                                                         shuffle: player.shuffle, repeatMode: player.repeatMode)
            }
            return "\(plan.displayName) · Blend in \(TimeFmt.mmss(countdown))\(playback.map { " · \($0)" } ?? "")"
        }
        guard let row = player.currentTrack else { return "" }
        return PlaybackDisplayPolicy.miniPlayerSubtitle(
            row: row,
            cacheState: player.cacheState,
            shuffle: player.shuffle,
            repeatMode: player.repeatMode
        )
    }
}

private extension TransitionPlan {
    var displayName: String {
        switch style {
        case .gapless: "Gapless continuation"
        case .beatmatchedBlend: "Beat-matched blend"
        case .phraseFade: "Phrase-aware fade"
        case .plainCrossfade: "Plain crossfade"
        }
    }
}

/// Watch transfer progress remains in the same accessory surface as the
/// player, with a specific state and a route into Settings for controls.
struct TransferPill: View {
    @EnvironmentObject var appState: AppState

    private var banner: PhoneWatchManagementPresenter.TransferBanner? {
        appState.watchManagement.banner
    }

    var body: some View {
        if let banner {
            Button {
                appState.showWatchSettings = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: banner.hasFailure
                          ? "exclamationmark.triangle.fill" : "applewatch")
                        .foregroundStyle(banner.hasFailure ? Palette.danger : Palette.accent)
                    Text(label(banner))
                        .font(Typography.caption)
                        .foregroundStyle(banner.hasFailure ? Palette.danger : Palette.inkSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Palette.inkTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .adaptiveGlass(cornerRadius: Metrics.glassCornerRadius)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label(banner))
            .accessibilityHint("Opens Apple Watch settings")
            .accessibilityIdentifier("watch.transferBanner")
        }
    }

    private func label(_ banner: PhoneWatchManagementPresenter.TransferBanner) -> String {
        if banner.hasFailure && banner.activeCount == 0 {
            return "\(banner.failedCount) download\(banner.failedCount == 1 ? "" : "s") failed"
        }
        if banner.hasFailure {
            return "\(banner.activeCount) transferring, \(banner.failedCount) failed"
        }
        return "\(banner.activeCount) transferring to Apple Watch"
    }
}
