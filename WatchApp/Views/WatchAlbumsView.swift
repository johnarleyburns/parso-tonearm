import SwiftUI
import TonearmWatchCore

struct WatchAlbumsView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model

    var body: some View {
        Group {
            if model.albums.isEmpty {
                WatchEmptyStateView(
                    icon: "square.stack",
                    title: "No Albums",
                    message: "Albums assembled from your downloaded songs will appear here.")
            } else {
                List {
                    ForEach(model.albums) { album in
                        NavigationLink(value: WatchNav.album(album.id)) {
                            WatchAlbumRow(album: album)
                        }
                    }
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("Albums")
        .task { await model.refresh() }
    }
}

struct WatchAlbumRow: View {
    let album: WatchAlbumGroup

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                LinearGradient(
                    colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(.body, design: .default))
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let artist = album.artist {
                    Text(artist)
                        .font(.system(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct WatchAlbumDetailView: View {
    let albumID: String
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var player = WatchPlayer.shared

    private var tracks: [WatchTrackSnapshot] { model.readyTracks(forAlbum: albumID) }

    var body: some View {
        List {
            if !tracks.isEmpty {
                Button {
                    player.play(tracks: tracks, startAt: 0)
                } label: {
                    HStack {
                        Image(systemName: "play.fill").font(.system(size: 14))
                        Text("Play All").font(.system(.body, design: .default)).fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("album.playAll")

                Button {
                    var shuffled = tracks
                    shuffled.shuffle()
                    player.play(tracks: shuffled, startAt: 0)
                } label: {
                    HStack {
                        Image(systemName: "shuffle").font(.system(size: 14))
                        Text("Shuffle").font(.system(.body, design: .default))
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                Button {
                    player.play(tracks: tracks, startAt: idx)
                } label: {
                    WatchTrackRow(track: track)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.carousel)
        .navigationTitle(model.album(id: albumID)?.title ?? "Album")
        .task { await model.refresh() }
    }
}

struct WatchSongsView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        Group {
            if model.tracks.isEmpty {
                WatchEmptyStateView(
                    icon: "music.note",
                    title: "No Songs",
                    message: "Songs you download from your iPhone will appear here.")
            } else {
                List {
                    ForEach(Array(model.tracks.prefix(5000).enumerated()), id: \.element.id) { idx, track in
                        Button {
                            player.play(tracks: model.tracks, startAt: idx)
                        } label: {
                            WatchTrackRow(track: track)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("Songs")
        .task { await model.refresh() }
    }
}
