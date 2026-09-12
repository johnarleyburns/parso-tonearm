import Foundation
import TonearmCore

public protocol PlaylistCrateImporting: Sendable {
    func availablePlaylists() async -> [CratePlaylistSummary]
    func tracks(in playlistID: Int64) async -> [CrateTrackSummary]
    func importCrate(playlistID: Int64, title: String) async throws -> CrateImportResult
}

public struct CratePlaylistSummary: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let trackCount: Int
    public init(id: Int64, title: String, trackCount: Int) {
        self.id = id; self.title = title; self.trackCount = trackCount
    }
}

public struct CrateTrackSummary: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let artist: String
    public let isOnDevice: Bool
    public init(id: Int64, title: String, artist: String, isOnDevice: Bool) {
        self.id = id; self.title = title; self.artist = artist; self.isOnDevice = isOnDevice
    }
}

public struct CrateImportResult: Equatable, Sendable {
    public let source: DeckQueueSource
    public let imported: Int
    public let skipped: Int
    public init(source: DeckQueueSource, imported: Int, skipped: Int) {
        self.source = source; self.imported = imported; self.skipped = skipped
    }
}

public struct PlaylistCrateImporter: PlaylistCrateImporting, Sendable {
    private let library: LibraryStore
    private let djLibrary: DJLibraryStore

    public init(library: LibraryStore = .shared, djLibrary: DJLibraryStore = .shared) {
        self.library = library
        self.djLibrary = djLibrary
    }

    public func availablePlaylists() async -> [CratePlaylistSummary] {
        let playlists = (try? await library.allPlaylists()) ?? []
        var summaries: [CratePlaylistSummary] = []
        for playlist in playlists {
            guard let id = playlist.id else { continue }
            let count = (try? await library.playlistTrackRows(playlistId: id).count) ?? 0
            summaries.append(CratePlaylistSummary(id: id, title: playlist.title, trackCount: count))
        }
        return summaries
    }

    public func tracks(in playlistID: Int64) async -> [CrateTrackSummary] {
        let rows = (try? await library.playlistTrackRows(playlistId: playlistID)) ?? []
        return rows.map { item in
            CrateTrackSummary(id: item.row.id, title: item.row.track.title,
                              artist: item.row.artist?.name ?? item.row.album?.artist ?? "",
                              isOnDevice: localURL(for: item.row) != nil)
        }
    }

    /// C02 (IMPLEMENT_CLAP_PLAN.md §3: "core playlist track IDs are already
    /// the IDs to use"): a crate is just the on-device subset of a core
    /// playlist's tracks, stored under their own **core** track IDs. No
    /// DJ-local `DJTrack`/`DJAsset` row is created — `saveCrate` writes core
    /// ids straight into `playlist_item` (dj_v8 dropped that column's FK into
    /// the DJ-local `track` table for exactly this reason).
    public func importCrate(playlistID: Int64, title: String) async throws -> CrateImportResult {
        let rows = try await library.playlistTrackRows(playlistId: playlistID)
        let ids = rows.compactMap { item -> Int64? in
            localURL(for: item.row) != nil ? item.row.id : nil
        }
        guard !ids.isEmpty else {
            throw CrateImporterError.noTracksOnDevice
        }
        let crateID = try await djLibrary.saveCrate(title: title, trackIDs: ids)
        return CrateImportResult(source: .playlist(id: crateID, title: title),
                                 imported: ids.count, skipped: rows.count - ids.count)
    }

    private func localURL(for row: TrackRow) -> URL? {
        guard let asset = row.asset else { return nil }
        if let bookmark = asset.bookmark, let (url, _) = BookmarkVault.resolve(bookmark),
           FileManager.default.fileExists(atPath: url.path) { return url }
        if let relPath = asset.relPath,
           let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask, appropriateFor: nil,
                                                   create: false) {
            let url = base.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if asset.kind == .remote, let raw = asset.remoteURL, let remote = URL(string: raw),
           AudioCache.completeCacheExists(for: remote) {
            return AudioCache.fileURL(for: AudioCache.key(for: remote))
        }
        return nil
    }

    public enum CrateImporterError: LocalizedError {
        case noTracksOnDevice
        public var errorDescription: String? { "No tracks in this playlist are on this device." }
    }
}
