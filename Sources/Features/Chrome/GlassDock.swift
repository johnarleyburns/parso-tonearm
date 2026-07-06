import SwiftUI

struct GlassDock: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        VStack(spacing: 9) {
            if player.currentTrack != nil {
                MiniPlayer()
                    .onTapGesture { appState.showNowPlaying = true }
            }
            TabBar(selection: $appState.tab)
        }
        .padding(.horizontal, 12)
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(seed: player.currentTrack?.album?.title ?? "np", cornerRadius: 10)
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
        if row.asset?.kind == .remote {
            switch player.cacheState {
            case .cached: return "archive.org · cached"
            case .filling: return "archive.org · caching…"
            case .none: return "archive.org"
            }
        }
        return row.album?.artist ?? "On Device"
    }
}

struct TabBar: View {
    @Binding var selection: AppTab

    private let items: [(AppTab, String, String)] = [
        (.listen, "play.circle.fill", "Listen"),
        (.playlists, "music.note.list", "Playlists"),
        (.library, "square.grid.2x2.fill", "Library"),
        (.sources, "cloud.fill", "Sources"),
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
