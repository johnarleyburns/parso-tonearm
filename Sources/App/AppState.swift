import Foundation
import SwiftUI

enum AppTab: Int, CaseIterable {
    case listen, playlists, library, sources, settings
}

enum PendingImport {
    case folder, files
}

@MainActor
final class AppState: ObservableObject {
    let store: LibraryStore

    @Published var tab: AppTab = .listen
    @Published var sources: [Source] = []
    @Published var playlists: [Playlist] = []
    @Published var allTracks: [TrackRow] = []
    @Published var recentlyPlayed: [TrackRow] = []
    @Published var recentlyAdded: [TrackRow] = []
    @Published var favoriteRows: [TrackRow] = []
    @Published var favoriteIds: Set<Int64> = []
    @Published var searchText: String = ""
    @Published var searchResults: [TrackRow] = []
    @Published var showAddMenu = false
    @Published var showNowPlaying = false
    @Published var showAddSource = false
    @Published var showFolderImporter = false
    @Published var showFileImporter = false
    @Published var showCreatePlaylist = false
    @Published var backgroundTitle: String?
    @Published var backgroundDone = false
    @Published var backgroundFailed = false
    @Published var pickedFolder: URL?
    @Published var pickedFolderBookmark: Data?
    @Published var pendingImport: PendingImport?
    // Settings-backed values
    @AppStorage("streamOnCellular") var streamOnCellular = true
    @AppStorage("preferFLAC") var preferFLAC = false
    @AppStorage("prefetchDepth") var prefetchDepth = 2
    @AppStorage("didOnboard") var didOnboard = false

    init(store: LibraryStore = .shared) {
        self.store = store
    }

    func bootstrap() async {
        await reload()
        applySettingsToPlayer()
        await CacheStore.shared.garbageCollectStalePartials()
    }

    func applySettingsToPlayer() {
        AudioPlayer.shared.streamOnCellular = streamOnCellular
        AudioPlayer.shared.prefetchDepth = prefetchDepth
        AudioPlayer.shared.preferFLAC = preferFLAC
    }

    func reload() async {
        do {
            sources = try await store.allSources()
            playlists = try await store.allPlaylists()
            allTracks = try await store.allTrackRows()
            recentlyPlayed = try await store.recentlyPlayedRows()
            recentlyAdded = try await store.recentlyAddedRows()
            favoriteRows = try await store.favoriteRows()
            favoriteIds = try await store.favoriteTrackIds()
        } catch {
            print("reload error: \(error)")
        }
    }

    func runSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        searchResults = (try? await store.search(searchText)) ?? []
    }

    func tracks(for source: Source) async -> [TrackRow] {
        guard let id = source.id else { return [] }
        return (try? await store.tracks(forSource: id)) ?? []
    }

    func firstArtworkId(for source: Source) async -> String? {
        guard let id = source.id else { return nil }
        return try? await store.firstArtworkId(forSource: id)
    }

    func deleteSource(_ source: Source) async {
        guard let id = source.id else { return }
        try? await store.deleteSource(id: id)
        await reload()
    }

    func addSourceInBackground(preview: SourcePreview, followUpdates: Bool) {
        let title = preview.title
        backgroundTitle = title
        backgroundDone = false
        backgroundFailed = false

        let pre = preview
        let upd = followUpdates
        let db = store
        let flac = preferFLAC

        Task {
            let service = SourceService(preferFLAC: flac)
            let source = try? await service.add(preview: pre, followUpdates: upd, store: db)
            if source != nil {
                backgroundDone = true
            } else {
                backgroundFailed = true
            }
            await reload()
            try? await Task.sleep(for: .seconds(4))
            backgroundTitle = nil
            backgroundDone = false
            backgroundFailed = false
        }
    }

    func playSource(_ source: Source, startAt: Int = 0) async {
        let tracks = await tracks(for: source)
        guard !tracks.isEmpty else { return }
        AudioPlayer.shared.play(tracks: tracks, startAt: startAt, source: .source(source))
    }

    // MARK: - Favorites (TF7)

    func isFavorite(_ row: TrackRow) -> Bool {
        favoriteIds.contains(row.id)
    }

    func toggleFavorite(_ row: TrackRow) async {
        let makeFavorite = !favoriteIds.contains(row.id)
        try? await store.setFavorite(trackId: row.id, makeFavorite)
        if makeFavorite { favoriteIds.insert(row.id) } else { favoriteIds.remove(row.id) }
        favoriteRows = (try? await store.favoriteRows()) ?? favoriteRows
    }

    // MARK: - Playlists (TF6)

    func createPlaylist(title: String, trackIds: [Int64]) async {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = try? await store.createManualPlaylist(title: name, trackIds: trackIds)
        await reload()
        tab = .playlists
    }

    // MARK: - Onboarding (TF5, TF9)

    /// Adds the given archive.org sources, persisting all of their tracks to the
    /// library (never caching), then builds the "Classical Piano Sonatas"
    /// starter playlist from every track that was added.
    func completeOnboarding(sourceURLs: [String]) async {
        let service = SourceService(preferFLAC: preferFLAC)
        var addedTrackIds: [Int64] = []
        for raw in sourceURLs {
            do {
                let preview = try await service.preview(from: raw)
                if let source = try? await service.add(preview: preview, followUpdates: true, store: store),
                   let sid = source.id {
                    let rows = (try? await store.tracks(forSource: sid)) ?? []
                    addedTrackIds.append(contentsOf: rows.map { $0.id })
                }
            } catch {
                print("onboarding add error for \(raw): \(error)")
            }
        }
        if !addedTrackIds.isEmpty {
            _ = try? await store.createManualPlaylist(title: "Classical Piano Sonatas",
                                                      trackIds: addedTrackIds)
        }
        didOnboard = true
        await reload()
    }
}
