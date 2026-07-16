import SwiftUI
import TonearmCore

struct PlaylistsView: View {
    @EnvironmentObject var appState: AppState
    @State private var playlistToRename: Playlist?
    @State private var renameTitle = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Playlists") { appState.showCreatePlaylist = true }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)

                Text("Your Playlists")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
                    .kerning(0.6)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)

                List {
                    NavigationLink(value: "ambient") {
                        NavigationRow(icon: "leaf.fill",
                                      title: "Ambient",
                                      subtitle: "Built-in nature sounds for focus, relaxation, or sleep")
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                    .listRowBackground(Color.clear)

                    ForEach(appState.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            NavigationRow(icon: playlist.kind == .folder ? "folder.fill" : "music.note.list",
                                          title: playlist.title,
                                          subtitle: playlist.kind == .folder ? "Folder playlist" : "Manual playlist")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                beginRename(playlist)
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                Task { await appState.deletePlaylist(playlist) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await appState.deletePlaylist(playlist) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                    .listRowBackground(Color.clear)

                    if appState.playlists.isEmpty {
                        EmptyStateView(icon: "music.note.list",
                                       title: "Create a playlist",
                                       message: "Tap + to create a playlist from your library, or add a local folder.")
                            .padding(.top, 24)
                            .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .foregroundStyle(Palette.ink)
            .background(Palette.libraryBackground.ignoresSafeArea())
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .navigationDestination(for: String.self) { value in
                if value == "ambient" { AmbientPlaylistView() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .renamePlaylistAlert(
                playlist: $playlistToRename,
                title: $renameTitle,
                submit: { playlist, title in
                    Task { await appState.renamePlaylist(playlist, title: title) }
                })
        }
    }

    private func beginRename(_ playlist: Playlist) {
        playlistToRename = playlist
        renameTitle = playlist.title
    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [PlaylistTrackRow] = []
    @State private var playlistToRename: Playlist?
    @State private var renameTitle = ""

    private var currentPlaylist: Playlist {
        guard let id = playlist.id else { return playlist }
        return appState.playlists.first(where: { $0.id == id }) ?? playlist
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15)).foregroundStyle(Palette.brass)
                        .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
                }
                Spacer()
                EditButton()
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.brass)
                Button {
                    beginRename(currentPlaylist)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14)).foregroundStyle(Palette.brass)
                        .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
                }
                .accessibilityLabel("Rename")
            }
            .padding(.top, 8)
            .padding(.horizontal, 18)

            Text(currentPlaylist.title)
                .font(.system(size: 26, weight: .heavy)).kerning(-0.5)
                .padding(.top, 12)
                .padding(.horizontal, 18)
            Text("\(tracks.count) tracks")
                .font(.system(size: 12.5)).foregroundStyle(Palette.ink3)
                .padding(.top, 2).padding(.bottom, 8)
                .padding(.horizontal, 18)

            List {
                ForEach(tracks) { item in
                    Button {
                        play(item)
                    } label: {
                        TrackRowView(row: item.row)
                    }
                    .buttonStyle(.plain)
                    .trackContextMenu(item.row)
                    .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: moveTracks)
                .onDelete(perform: deleteTracks)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.libraryBackground.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .task(id: currentPlaylist.id) {
            await loadTracks()
        }
        .renamePlaylistAlert(
            playlist: $playlistToRename,
            title: $renameTitle,
            submit: { playlist, title in
                Task { await appState.renamePlaylist(playlist, title: title) }
            })
    }

    private func play(_ item: PlaylistTrackRow) {
        guard let index = tracks.firstIndex(where: { $0.id == item.id }) else { return }
        player.play(tracks: tracks.map(\.row), startAt: index, source: .playlist(currentPlaylist))
    }

    private func moveTracks(from source: IndexSet, to destination: Int) {
        tracks = rows(for: PlaylistEditor.move(tracks.map(\.item), fromOffsets: source, toOffset: destination))
        Task {
            await appState.reorderPlaylist(currentPlaylist, fromOffsets: source, toOffset: destination)
            await loadTracks()
        }
    }

    private func deleteTracks(at offsets: IndexSet) {
        tracks = rows(for: PlaylistEditor.remove(tracks.map(\.item), atOffsets: offsets))
        Task {
            await appState.removeFromPlaylist(currentPlaylist, atOffsets: offsets)
            await loadTracks()
        }
    }

    private func rows(for items: [PlaylistItem]) -> [PlaylistTrackRow] {
        items.compactMap { item in
            tracks.first(where: { $0.item.id == item.id }).map { existing in
                PlaylistTrackRow(item: item, row: existing.row)
            }
        }
    }

    private func loadTracks() async {
        guard let id = currentPlaylist.id else { return }
        tracks = (try? await appState.store.playlistTrackRows(playlistId: id)) ?? []
    }

    private func beginRename(_ playlist: Playlist) {
        playlistToRename = playlist
        renameTitle = playlist.title
    }
}

private extension View {
    func renamePlaylistAlert(
        playlist: Binding<Playlist?>,
        title: Binding<String>,
        submit: @escaping (Playlist, String) -> Void
    ) -> some View {
        alert("Rename Playlist", isPresented: Binding(
            get: { playlist.wrappedValue != nil },
            set: { if !$0 { playlist.wrappedValue = nil } }
        )) {
            TextField("Name", text: title)
            Button("Cancel", role: .cancel) {
                playlist.wrappedValue = nil
            }
            Button("Save") {
                if let playlist = playlist.wrappedValue {
                    submit(playlist, title.wrappedValue)
                }
                playlist.wrappedValue = nil
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
