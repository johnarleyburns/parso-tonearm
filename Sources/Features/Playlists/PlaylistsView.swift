import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenHeader(title: "Playlists") { appState.showCreatePlaylist = true }
                        .padding(.bottom, 12)

                    NavigationLink(value: "ambient") {
                        NavigationRow(icon: "leaf.fill",
                                      title: "Ambient",
                                      subtitle: "Built-in nature sounds for focus, relaxation, or sleep")
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 18)

                    if appState.playlists.isEmpty {
                        EmptyStateView(icon: "music.note.list",
                                       title: "No playlists yet",
                                       message: "Tap + to create a playlist from your library, or add a local folder.")
                            .padding(.top, 60)
                    } else {
                        Text("Your Playlists")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.ink3)
                            .kerning(0.6)
                            .padding(.bottom, 6)

                        ForEach(appState.playlists) { playlist in
                            NavigationLink(value: playlist) {
                                NavigationRow(icon: playlist.kind == .folder ? "folder.fill" : "music.note.list",
                                              title: playlist.title,
                                              subtitle: playlist.kind == .folder ? "Folder playlist" : "Manual playlist")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 160)
            }
            .foregroundStyle(Palette.ink)
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .navigationDestination(for: String.self) { value in
                if value == "ambient" { AmbientPlaylistView() }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [TrackRow] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15)).foregroundStyle(Palette.brass)
                            .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
                    }
                    Spacer()
                }
                .padding(.top, 8)

                Text(playlist.title)
                    .font(.system(size: 26, weight: .heavy)).kerning(-0.5)
                    .padding(.top, 12)
                Text("\(tracks.count) tracks")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.ink3)
                    .padding(.top, 2).padding(.bottom, 14)

                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, row in
                    Button {
                        player.play(tracks: tracks, startAt: idx)
                    } label: { TrackRowView(row: row) }
                    .buttonStyle(.plain)
                    .trackContextMenu(row)
                    Divider().overlay(Palette.hairline)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
        .navigationBarBackButtonHidden()
        .task {
            if let id = playlist.id {
                tracks = (try? await appState.store.playlistItems(playlistId: id)) ?? []
            }
        }
    }
}

struct NavigationRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Palette.brass)
                .frame(width: 42, height: 42)
                .glassSurface(cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 8)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundStyle(Palette.ink3)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }
}
