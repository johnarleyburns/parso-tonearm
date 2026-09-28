import SwiftUI
import TonearmCore

struct GlassDock: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        VStack(spacing: 9) {
            if appState.tab != .dj, hasDJTrack {
                DJMiniPlayer(model: appState.djPerformanceModel)
                    .onTapGesture {
                        appState.tab = .dj
                    }
            }
            if player.currentTrack != nil && !appState.showNowPlaying {
                MiniPlayer()
                    .onTapGesture { appState.showNowPlaying = true }
            }
            TransferPill()
            TabBar(selection: $appState.tab)
        }
        .padding(.horizontal, 12)
    }

    private var hasDJTrack: Bool {
        appState.djPerformanceModel.deckA.row != nil || appState.djPerformanceModel.deckB.row != nil
    }
}

private struct DJMiniPlayer: View {
    @ObservedObject var model: DJPerformanceModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(Palette.brass)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .foregroundStyle(Palette.ink)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 14))
        .adaptiveGlass(cornerRadius: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Return to DJ")
        .accessibilityValue(subtitle)
    }

    private var title: String {
        let a = model.deckA.row?.track.title
        let b = model.deckB.row?.track.title
        if let a, let b { return "A " + a + " · B " + b }
        return a ?? b ?? "Platterhead DJ"
    }

    private var playing: Bool { model.deckA.isPlaying || model.deckB.isPlaying }
    private var subtitle: String { playing ? "DJ playing · tap to return" : "DJ paused · tap to return" }
}

/// Watch rearchitecture Phase 8 (P5): compact transfer progress with a failure affordance. Never
/// covers transport controls (it sits in the dock stack) and stays a single tappable target that
/// opens Settings › Apple Watch.
struct TransferPill: View {
    @EnvironmentObject var appState: AppState

    private var banner: PhoneWatchManagementPresenter.TransferBanner? { appState.watchManagement.banner }

    var body: some View {
        if let banner {
            Button {
                appState.showWatchSettings = true
            } label: {
                HStack(spacing: 6) {
                    if banner.hasFailure {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.danger)
                    } else {
                        ProgressView().scaleEffect(0.65).tint(Palette.brass)
                    }
                    Text(label(banner))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(banner.hasFailure ? Palette.danger : Palette.ink2)
                    Spacer()
                    Image(systemName: "applewatch")
                        .font(.system(size: 12))
                        .foregroundStyle(banner.hasFailure ? Palette.danger : Palette.brass)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("watch.transferBanner")
            // Without this, VoiceOver reads every glyph individually
            // ("warning image", "apple watch image") ahead of the real
            // label — a real label collapses it to one clean announcement.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label(banner))
        }
    }

    private func label(_ b: PhoneWatchManagementPresenter.TransferBanner) -> String {
        if b.hasFailure && b.activeCount == 0 {
            return "\(b.failedCount) download\(b.failedCount == 1 ? "" : "s") failed"
        }
        if b.hasFailure {
            return "\(b.activeCount) transferring · \(b.failedCount) failed"
        }
        return "\(b.activeCount) transferring to Apple Watch"
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(trackRow: player.currentTrack,
                        seed: player.currentTrack?.album?.title ?? "np",
                        cornerRadius: 10)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentTrack?.track.title ?? "")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("mini.title")
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 16) {
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("mini.playpause")
                .accessibilityValue(player.isPlaying ? "playing" : "paused")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                }
                .accessibilityLabel("Next Track")
                .accessibilityIdentifier("mini.next")
            }
            .font(.system(size: 16))
            .foregroundStyle(Palette.ink)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 14))
        .adaptiveGlass(cornerRadius: 22)
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

struct TabBar: View {
    @Binding var selection: AppTab

    private let items: [(AppTab, String, String)] = [
        (.listen, "play.circle.fill", "Listen"),
        (.myMusic, "square.grid.2x2.fill", "My Music"),
        (.dj, "slider.horizontal.3", "DJ"),
        (.settings, "gearshape.fill", "Settings")
    ]

    var body: some View {
        HStack {
            ForEach(items, id: \.0) { tab, icon, label in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon).font(.system(size: 18))
                        Text(label).font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(selection == tab ? Palette.brass : Palette.ink3)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(label)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .adaptiveGlass(cornerRadius: 26)
    }
}
