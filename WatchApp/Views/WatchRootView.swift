import SwiftUI
import TonearmCore

struct WatchRootView: View {
    @State private var playlists: [Playlist] = []
    @State private var albumCount: Int = 0
    @State private var trackCount: Int = 0
    @State private var onWatchTracks: Int = 0
    @State private var onWatchBytes: Int64 = 0

    var body: some View {
        List {
            nowPlayingChip

            NavigationLink(value: WatchNav.playlists) {
                WatchCollectionRow(
                    title: "Playlists",
                    subtitle: "\(playlists.count) playlists",
                    systemImage: "music.note.list")
            }
            .accessibilityIdentifier("root.playlists")

            NavigationLink(value: WatchNav.albums) {
                WatchCollectionRow(
                    title: "Albums",
                    subtitle: "\(albumCount) albums",
                    systemImage: "square.stack")
            }
            .accessibilityIdentifier("root.albums")

            NavigationLink(value: WatchNav.songs) {
                WatchCollectionRow(
                    title: "Songs",
                    subtitle: "\(trackCount) tracks",
                    systemImage: "music.note")
            }
            .accessibilityIdentifier("root.songs")

            NavigationLink(value: WatchNav.storage) {
                WatchCollectionRow(
                    title: "Storage",
                    subtitle: onWatchBytes > 0
                            ? "\(onWatchTracks) tracks · \(WatchTimeFmt.megabytes(onWatchBytes))"
                        : "Manage storage",
                    systemImage: "internaldrive")
            }
            .accessibilityIdentifier("root.storage")
        }
        .listStyle(.carousel)
        .navigationTitle("Platterhead")
        .task {
            await load()
            await WatchPlayer.shared.restorePositionIfAvailable()
        }
    }

    @ViewBuilder
    private var nowPlayingChip: some View {
        if let track = WatchPlayer.shared.currentTrack {
            NavigationLink(value: WatchNav.nowPlaying) {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.track.title)
                            .font(.system(.caption, design: .default))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("Now Playing")
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: WatchPlayer.shared.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                }
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("root.nowPlaying")
        }
    }

    private func load() async {
        let store = LibraryStore.shared
        playlists = (try? await store.allPlaylists()) ?? []
        albumCount = ((try? await store.allAlbums()) ?? []).count
        trackCount = ((try? await store.allTracks()) ?? []).count
        let records = (try? await store.dbQueue.read { db in
            try WatchManifestRecord.fetchAll(db)
        }) ?? []
        onWatchTracks = records.count
        onWatchBytes = records.reduce(0) { $0 + $1.bytes }
    }
}

enum WatchNav: Hashable {
    case playlists
    case albums
    case songs
    case storage
    case nowPlaying
    case playlist(Playlist)
    case album(Album)
}
