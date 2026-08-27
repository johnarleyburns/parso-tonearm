import SwiftUI
import TonearmWatchCore

struct WatchPlaylistsView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model

    var body: some View {
        Group {
            if model.playlists.isEmpty {
                WatchEmptyStateView(
                    icon: "music.note.list",
                    title: "No Playlists",
                    message: "Playlists you download from your iPhone will appear here.")
            } else {
                List {
                    ForEach(model.playlists) { playlist in
                        NavigationLink(value: WatchNav.playlist(playlist.id)) {
                            WatchCollectionRow(
                                title: playlist.title,
                                subtitle: subtitle(for: playlist),
                                systemImage: "music.note.list")
                        }
                    }
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("Playlists")
        .task { await model.refresh() }
    }

    private func subtitle(for playlist: WatchPlaylistSnapshot) -> String {
        "\(playlist.readyTrackIDs.count) tracks"
    }
}

struct WatchPlaylistDetailView: View {
    let playlistID: String
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var player = WatchPlayer.shared

    private var tracks: [WatchTrackSnapshot] { model.readyTracks(forPlaylist: playlistID) }

    var body: some View {
        List {
            if !tracks.isEmpty {
                Button {
                    player.play(tracks: tracks, startAt: 0)
                } label: {
                    playAllLabel
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("playlist.playAll")

                Button {
                    var shuffled = tracks
                    shuffled.shuffle()
                    player.play(tracks: shuffled, startAt: 0)
                } label: {
                    shuffleLabel
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
        .navigationTitle(model.playlist(id: playlistID)?.title ?? "Playlist")
        .task { await model.refresh() }
    }

    private var playAllLabel: some View {
        HStack {
            Image(systemName: "play.fill").font(.system(size: 14))
            Text("Play All").font(.system(.body, design: .default)).fontWeight(.semibold)
            Spacer()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var shuffleLabel: some View {
        HStack {
            Image(systemName: "shuffle").font(.system(size: 14))
            Text("Shuffle").font(.system(.body, design: .default))
            Spacer()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
