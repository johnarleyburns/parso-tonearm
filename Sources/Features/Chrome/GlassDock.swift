import SwiftUI
import TonearmCore

struct GlassDock: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        VStack(spacing: 9) {
            if player.currentTrack != nil && !appState.showNowPlaying {
                MiniPlayer()
                    .onTapGesture { appState.showNowPlaying = true }
            }
            TransferPill()
            TabBar(selection: $appState.tab)
        }
        .padding(.horizontal, 12)
    }
}

struct TransferPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.watchTransferActiveCount > 0 {
            Button {
                appState.showWatchSettings = true
            } label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(Palette.brass)
                    Text("\(appState.watchTransferActiveCount) transferring to Watch")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                    Spacer()
                    Image(systemName: "applewatch")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.brass)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
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
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                }
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
        (.playlists, "music.note.list", "Playlists"),
        (.library, "square.grid.2x2.fill", "Music"),
        (.sources, "cloud.fill", "Libraries"),
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
