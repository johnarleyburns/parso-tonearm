import SwiftUI
import TonearmWatchCore

struct WatchRootView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        List {
            nowPlayingChip

            NavigationLink(value: WatchNav.playlists) {
                WatchCollectionRow(
                    title: "Playlists",
                    subtitle: "\(model.playlists.count) playlists",
                    systemImage: "music.note.list")
            }
            .accessibilityIdentifier("root.playlists")

            NavigationLink(value: WatchNav.albums) {
                WatchCollectionRow(
                    title: "Albums",
                    subtitle: "\(model.albums.count) albums",
                    systemImage: "square.stack")
            }
            .accessibilityIdentifier("root.albums")

            NavigationLink(value: WatchNav.songs) {
                WatchCollectionRow(
                    title: "Songs",
                    subtitle: "\(model.tracks.count) tracks",
                    systemImage: "music.note")
            }
            .accessibilityIdentifier("root.songs")

            NavigationLink(value: WatchNav.storage) {
                WatchCollectionRow(
                    title: "Storage",
                    subtitle: storageSubtitle,
                    systemImage: "internaldrive")
            }
            .accessibilityIdentifier("root.storage")
        }
        .listStyle(.carousel)
        .navigationTitle("Platterhead")
        .task { await model.refresh() }
    }

    private var storageSubtitle: String {
        guard let storage = model.storage, storage.readyBytes > 0 else { return "Manage storage" }
        return "\(model.tracks.count) tracks · \(WatchTimeFmt.megabytes(storage.readyBytes))"
    }

    @ViewBuilder
    private var nowPlayingChip: some View {
        if let track = player.currentTrack {
            Button {
                player.navigateToNowPlaying()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(.caption, design: .default))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("Now Playing")
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("root.nowPlaying")
        }
    }
}

enum WatchNav: Hashable {
    case playlists
    case albums
    case songs
    case storage
    case playlist(String)
    case album(String)
}
