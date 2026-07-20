import SwiftUI
import TonearmCore

struct WatchAlbumsView: View {
    @State private var albums: [Album] = []

    var body: some View {
        Group {
            if albums.isEmpty {
                WatchEmptyStateView(
                    icon: "square.stack",
                    title: "No Albums",
                    message: "Albums synced from your iPhone will appear here.")
            } else {
                List {
                    ForEach(albums) { album in
                        NavigationLink(value: WatchNav.album(album)) {
                            WatchAlbumRow(album: album)
                        }
                    }
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("Albums")
        .task { await load() }
    }

    private func load() async {
        albums = (try? await LibraryStore.shared.allAlbums()) ?? []
    }
}

struct WatchAlbumRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 10) {
            albumArtwork
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(.body, design: .default))
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let artist = album.artist ?? album.albumArtist {
                    Text(artist)
                        .font(.system(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var albumArtwork: some View {
        if let artworkId = album.artworkId {
            Color.clear
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                )
                .background(
                    LinearGradient(
                        colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        } else {
            ZStack {
                LinearGradient(
                    colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WatchAlbumDetailView: View {
    let album: Album
    @State private var tracks: [TrackRow] = []

    var body: some View {
        List {
            if !tracks.isEmpty {
                Button {
                    WatchPlayer.shared.play(tracks: tracks, startAt: 0)
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
                }
                .buttonStyle(.plain)

                Button {
                    var shuffled = tracks
                    shuffled.shuffle()
                    WatchPlayer.shared.play(tracks: shuffled, startAt: 0)
                } label: {
                    HStack {
                        Image(systemName: "shuffle")
                            .font(.system(size: 14))
                        Text("Shuffle")
                            .font(.system(.body, design: .default))
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, row in
                Button {
                    WatchPlayer.shared.play(tracks: tracks, startAt: idx)
                } label: {
                    WatchTrackRow(row: row)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.carousel)
        .navigationTitle(album.title)
        .task { await load() }
    }

    private func load() async {
        guard let id = album.id else { return }
        let allRows = (try? await LibraryStore.shared.allTrackRows()) ?? []
        tracks = allRows.filter { $0.track.albumId == id }
    }
}

struct WatchSongsView: View {
    @State private var tracks: [TrackRow] = []

    var body: some View {
        Group {
            if tracks.isEmpty {
                WatchEmptyStateView(
                    icon: "music.note",
                    title: "No Songs",
                    message: "Songs synced from your iPhone will appear here.")
            } else {
                List {
                    ForEach(Array(tracks.prefix(5000).enumerated()), id: \.element.id) { idx, row in
                        Button {
                            WatchPlayer.shared.play(tracks: tracks, startAt: idx)
                        } label: {
                            WatchTrackRow(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("Songs")
        .task { await load() }
    }

    private func load() async {
        tracks = ((try? await LibraryStore.shared.allTrackRows()) ?? [])
            .sorted { a, b in
                let aKey = a.track.sortKey ?? a.track.title
                let bKey = b.track.sortKey ?? b.track.title
                return aKey.localizedCaseInsensitiveCompare(bKey) == .orderedAscending
            }
    }
}
