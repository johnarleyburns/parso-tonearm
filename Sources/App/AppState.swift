import Foundation
import SwiftUI

enum AppTab: Int, CaseIterable {
    case listen, playlists, library, sources, settings
}

enum PendingImport: Equatable {
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
    @AppStorage("artworkLookup") var artworkLookup = true
    @AppStorage("didOnboard") var didOnboard = false

    init(store: LibraryStore = .shared) {
        self.store = store
    }

    func bootstrap() async {
        await fixLegacySourceTitles()
        await ArtworkService.shared.migrateCacheIfNeeded()
        await reload()
        applySettingsToPlayer()
        await CacheStore.shared.garbageCollectStalePartials()
        Task { await warmLocalSourceArtwork() }
    }

    /// Resolves and caches a representative cover for local sources that don't yet
    /// have one remembered, so app-update installs pick up embedded artwork without
    /// waiting for each tile to appear. Runs off the launch critical path.
    private func warmLocalSourceArtwork() async {
        let locals = sources.filter { $0.kind == .local && $0.artworkTrackId == nil }
        guard !locals.isEmpty else { return }
        for source in locals {
            _ = await resolvedArtwork(for: source)
        }
        // Pick up the persisted artworkTrackId values so tiles use the remembered
        // pick directly instead of rescanning.
        await reload()
    }

    /// One-time repair for sources saved before the list/collection naming fix:
    /// re-derive human-readable titles from the stored originalURL slug.
    func fixLegacySourceTitles() async {
        guard let existing = try? await store.allSources() else { return }
        for source in existing {
            guard let id = source.id else { continue }
            var newTitle: String?

            switch source.kind {
            case .iaList:
                if let raw = source.originalURL,
                   case .list(_, _, let slug)? = try? URLGrammar.parse(raw).get(),
                   let slug, !slug.isEmpty {
                    newTitle = SourceService.prettify(slug)
                }
            case .iaCollection:
                // Buggy rows stored the raw identifier as the title.
                if let idf = source.iaIdentifier, source.title == idf {
                    newTitle = SourceService.prettify(idf)
                }
            default:
                break
            }

            if let newTitle, !newTitle.isEmpty, newTitle != source.title {
                try? await store.updateSourceTitle(id: id, title: newTitle)
            }
        }
    }

    func applySettingsToPlayer() {
        AudioPlayer.shared.streamOnCellular = streamOnCellular
        AudioPlayer.shared.prefetchDepth = PrefetchDepthPolicy.clamp(prefetchDepth)
        AudioPlayer.shared.preferFLAC = preferFLAC
        let lookup = artworkLookup
        Task { await ArtworkService.shared.setArtworkLookupEnabled(lookup) }
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
        guard let ids = try? await store.artworkIds(forSource: id), !ids.isEmpty else { return nil }
        return await ArtworkService.shared.firstAvailableIdentifier(ids)
    }

    /// Resolved artwork inputs for a source tile: an IA identifier and/or a local
    /// track carrying embedded art, plus the per-kind fallback icon. For local
    /// sources the representative track is chosen once and remembered (cached)
    /// via `artworkTrackId`.
    struct ResolvedSourceArtwork {
        var identifier: String?
        var trackRow: TrackRow?
        var fallbackIcon: String
    }

    func resolvedArtwork(for source: Source) async -> ResolvedSourceArtwork {
        let icon = source.fallbackIcon
        guard let id = source.id else {
            return ResolvedSourceArtwork(identifier: nil, trackRow: nil, fallbackIcon: icon)
        }

        if source.kind == .local {
            let row = await representativeLocalTrackRow(for: source, sourceId: id)
            return ResolvedSourceArtwork(identifier: nil, trackRow: row, fallbackIcon: icon)
        }

        // IA: prefer a resolvable IA identifier cover.
        if let identifier = await firstArtworkId(for: source) {
            return ResolvedSourceArtwork(identifier: identifier, trackRow: nil, fallbackIcon: icon)
        }
        // No IA cover: fall back to a representative track so the tile can still get
        // an iTunes cover from the album's artist/title (same path as Now Playing).
        if let row = try? await store.firstTrackRow(forSource: id),
           await ArtworkService.shared.artwork(forTrackRow: row) != nil {
            return ResolvedSourceArtwork(identifier: nil, trackRow: row, fallbackIcon: icon)
        }
        return ResolvedSourceArtwork(identifier: nil, trackRow: nil, fallbackIcon: icon)
    }

    /// Picks the first local track with resolvable artwork, preferring a previously
    /// remembered `artworkTrackId`. Only a strong (persistable) match is remembered
    /// as the source's representative; weak iTunes guesses are shown but not locked in.
    private func representativeLocalTrackRow(for source: Source, sourceId: Int64) async -> TrackRow? {
        if let remembered = source.artworkTrackId,
           let row = try? await store.trackRow(id: remembered),
           await ArtworkService.shared.artwork(forTrackRow: row) != nil {
            return row
        }

        let rows = (try? await store.tracks(forSource: sourceId)) ?? []
        var firstWithArt: TrackRow?
        for row in rows {
            guard let result = await ArtworkService.shared.trackArtwork(forTrackRow: row) else { continue }
            if firstWithArt == nil { firstWithArt = row }
            if result.persistable {
                try? await store.setSourceArtworkTrack(id: sourceId, trackId: row.id)
                return row
            }
        }
        // No strong match: show the first weak guess without remembering it.
        return firstWithArt
    }

    func deleteSource(_ source: Source) async {
        guard let id = source.id else { return }
        // Delete custom artwork files from disk before the cascade removes DB rows.
        if let artworkIds = try? await store.customArtworkIds(forSource: id) {
            for aid in artworkIds { await ArtworkStore.shared.delete(id: aid) }
        }
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

    func deletePlaylist(_ playlist: Playlist) async {
        guard let id = playlist.id else { return }
        try? await store.deletePlaylist(id: id)
        await reload()
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
