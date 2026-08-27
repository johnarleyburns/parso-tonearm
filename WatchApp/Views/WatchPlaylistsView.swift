import SwiftUI
import TonearmWatchLegacyCore

struct WatchPlaylistsView: View {
    @State private var playlists: [LegacyWatchPlaylist] = []

    var body: some View {
        Group {
            if playlists.isEmpty {
                WatchEmptyStateView(
                    icon: "music.note.list",
                    title: "No Playlists",
                    message: "Playlists synced from your iPhone will appear here.")
            } else {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: WatchNav.playlist(playlist)) {
                            WatchCollectionRow(
                                title: playlist.title,
                                subtitle: playlist.kind == .folder ? "Folder" : "Manual",
                                systemImage: playlist.kind == .folder ? "folder.fill" : "music.note.list")
                        }
                    }
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("Playlists")
        .task { await load() }
    }

    private func load() async {
        playlists = (try? await LegacyWatchLibraryStore.shared.allPlaylists()) ?? []
    }
}

struct WatchPlaylistDetailView: View {
    let playlist: LegacyWatchPlaylist
    @State private var tracks: [LegacyWatchPlaylistTrackRow] = []

    var body: some View {
        List {
            if !tracks.isEmpty {
                Button {
                    let rows = tracks.map(\.row)
                    if !rows.isEmpty {
                        WatchPlayer.shared.play(tracks: rows, startAt: 0)
                    }
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14))
                        Text("Play All")
                            .font(.system(.body, design: .default))
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("playlist.playAll")

                Button {
                    var rows = tracks.map(\.row)
                    if !rows.isEmpty {
                        rows.shuffle()
                        WatchPlayer.shared.play(tracks: rows, startAt: 0)
                    }
                } label: {
                    HStack {
                        Image(systemName: "shuffle")
                            .font(.system(size: 14))
                        Text("Shuffle")
                            .font(.system(.body, design: .default))
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(tracks) { item in
                Button {
                    if let idx = tracks.firstIndex(where: { $0.id == item.id }) {
                        WatchPlayer.shared.play(tracks: tracks.map(\.row), startAt: idx)
                    }
                } label: {
                    WatchTrackRow(row: item.row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.carousel)
        .navigationTitle(playlist.title)
        .task { await load() }
    }

    private func load() async {
        guard let id = playlist.id else { return }
        tracks = (try? await LegacyWatchLibraryStore.shared.playlistTrackRows(playlistId: id)) ?? []
    }
}
