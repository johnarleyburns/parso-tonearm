import SwiftUI
import TonearmCore

struct PlaylistsView: View {
    @EnvironmentObject var appState: AppState
    private let presentsCreateSheetLocally: Bool
    /// My Music already owns a `NavigationStack` when embedding this view as
    /// a scope — a second nested stack there makes the first push unstable
    /// (same reasoning as `LibraryView.ownsNavigationStack`).
    private let ownsNavigationStack: Bool
    @State private var showLocalCreate = false
    @State private var playlistToRename: Playlist?
    @State private var renameTitle = ""

    init(presentsCreateSheetLocally: Bool = false, ownsNavigationStack: Bool = true) {
        self.presentsCreateSheetLocally = presentsCreateSheetLocally
        self.ownsNavigationStack = ownsNavigationStack
    }

    var body: some View {
        Group {
            if ownsNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Playlists") {
                    if presentsCreateSheetLocally { showLocalCreate = true }
                    else { appState.showCreatePlaylist = true }
                }
                    .accessibilityIdentifier("playlists.create")
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)

                Text("Your Playlists")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
                    .kerning(0.6)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)

                List {
                    // NavigationRow already draws its own trailing chevron
                    // for this app's custom row styling — wrapping it
                    // directly in `NavigationLink(value:) { ... }` also gets
                    // SwiftUI's OWN built-in disclosure chevron in a `List`,
                    // producing two ">" glyphs (real regression report: "I'm
                    // seeing the 'double >' again"). Fix: an invisible
                    // NavigationLink drives navigation while `NavigationRow`
                    // stays plain content — same tap target, only one
                    // visible chevron. A `.background(...)`-attached
                    // NavigationLink plus `.accessibilityHidden(true)` was
                    // tried first but still left TWO accessibility elements
                    // (the NavigationLink's own Button trait survives
                    // `accessibilityHidden` inside a `List` row in practice).
                    // Putting both views in a `ZStack` and combining at THAT
                    // level merges everything, NavigationLink's Button trait
                    // included, into one accessibility element with one
                    // identifier — which is what XCUITest's single-match
                    // identifier lookup needs.
                    ZStack(alignment: .leading) {
                        NavigationLink(value: "ambient") { EmptyView() }.opacity(0)
                        NavigationRow(icon: "leaf.fill",
                                      title: "Ambient",
                                      subtitle: "Built-in nature sounds for focus, relaxation, or sleep")
                    }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("playlist.ambient")
                        .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                        .listRowBackground(Color.clear)

                    ForEach(appState.playlists) { playlist in
                        ZStack(alignment: .leading) {
                            NavigationLink(value: playlist) { EmptyView() }.opacity(0)
                            PlaylistNavigationRow(playlist: playlist)
                        }
                            .accessibilityElement(children: .combine)
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
                                       message: "Tap + to create a playlist from Music, or add a local folder.")
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
            .sheet(isPresented: $showLocalCreate) {
                CreatePlaylistSheet(isEmbedded: true)
            }
            .renamePlaylistAlert(
                playlist: $playlistToRename,
                title: $renameTitle,
                submit: { playlist, title in
                    Task { await appState.renamePlaylist(playlist, title: title) }
                })
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
    @State private var showAddTracks = false

    private var currentPlaylist: Playlist {
        guard let id = playlist.id else { return playlist }
        return appState.playlists.first(where: { $0.id == id }) ?? playlist
    }

    private var trackRows: [TrackRow] {
        tracks.map(\.row)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.brass)
                        .frame(width: 44, height: 44).glassSurface(cornerRadius: 22)
                }
                .accessibilityLabel("Back")
                .accessibilityIdentifier("playlist.back")
                Spacer()
                EditButton()
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("playlist.edit")
                Button { showAddTracks = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.brass)
                        .frame(width: 44, height: 44).glassSurface(cornerRadius: 22)
                }
                .accessibilityIdentifier("playlist.add")
                Menu {
                    if trackRows.count >= 2 {
                        Button {
                            appState.pendingTransitionLabPair = (trackRows[0], trackRows[1])
                            appState.tab = .dj
                        } label: {
                            Label("Practice transitions", systemImage: "waveform.path.ecg")
                        }
                        .accessibilityIdentifier("mymusic.playlist.practiceTransitions")
                    }
                    Button {
                        beginRename(currentPlaylist)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        Task { await appState.download(rows: trackRows) }
                    } label: {
                        Label("Download All", systemImage: "arrow.down.circle")
                    }
                    Button {
                        Task { await appState.downloadAllToWatch(playlistId: currentPlaylist.id ?? -1) }
                    } label: {
                        Label("Download All to Apple Watch", systemImage: "applewatch")
                    }
                    Button {
                        Task { await appState.removeAllFromWatch() }
                    } label: {
                        Label("Remove All from Apple Watch", systemImage: "applewatch.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14)).foregroundStyle(Palette.brass)
                        .frame(width: 44, height: 44).glassSurface(cornerRadius: 22)
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("playlist.overflow")
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
                        TrackRowView(row: item.row, showArtwork: true)
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
        .sheet(isPresented: $showAddTracks) {
            AddTracksToPlaylistSheet(playlist: currentPlaylist) { await loadTracks() }
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

/// A playlist row that shows real artwork from its first track (real request: "I want each
/// playlist to have artwork from its underlying tracks") instead of one generic icon shared by
/// every playlist. Its own tiny view so it can hold the fetched track in `@State` without
/// touching `NavigationRow`'s existing (icon-only) callers — the same lazy-per-row `.task` pattern
/// `ArtworkView`/`TrackRowView` already use for lists that can hold many rows.
private struct PlaylistNavigationRow: View {
    let playlist: Playlist
    @EnvironmentObject var appState: AppState
    @State private var firstTrack: TrackRow?

    var body: some View {
        NavigationRow(
            icon: playlist.kind == .folder ? "folder.fill" : "music.note.list",
            title: playlist.title,
            subtitle: playlist.kind == .folder ? "Folder playlist" : "Manual playlist",
            leadingArtwork: firstTrack)
            .task(id: playlist.id) {
                guard let id = playlist.id else { return }
                firstTrack = (try? await appState.store.playlistItems(playlistId: id))?.first
            }
    }
}

struct NavigationRow: View {
    let icon: String
    let title: String
    let subtitle: String
    /// When set, a real track's artwork (or its deterministic color-identity gradient, from
    /// `ArtworkView`) replaces the plain SF Symbol tile — used for playlist rows so each playlist
    /// reads by its own music, not one generic icon shared by every playlist in the list.
    var leadingArtwork: TrackRow? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let leadingArtwork {
                ArtworkView(trackRow: leadingArtwork, seed: title, cornerRadius: 10,
                            fallbackIcon: icon, thumbnailMaxDimension: 84)
                    .frame(width: 42, height: 42)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 42, height: 42)
                    .glassSurface(cornerRadius: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 8)
        // Now that this is plain content (not wrapped directly in
        // NavigationLink — see the chevron fix above), it must explicitly
        // collapse into ONE accessibility element itself; without this each
        // child (icon/title/subtitle/chevron) exposes its own element, all
        // carrying whatever `.accessibilityIdentifier` the caller applies to
        // the row as a whole — which broke the UI smoke test ("Multiple
        // matching elements found for identifier 'playlist.ambient'").
        .accessibilityElement(children: .combine)
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
