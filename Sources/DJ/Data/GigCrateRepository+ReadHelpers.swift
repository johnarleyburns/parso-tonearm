import Foundation
import GRDB
import TonearmCore

// MARK: - Read helpers (C02: crate members are core track ids)
//
// `fetchCrateRows`, `fetchTrackRows`, and `isAudioCached` are called from
// `GigCrateRepository.swift`'s `promote`/`crates`/`detail`/`cratesByLRU` and
// from `GigCrateRepository+Mutations.swift`'s `refreshAudioCached` — all in
// different files, so they are kept at the implicit internal access level
// rather than `private`. `analyzedCount` and `resolveAudioURL` are used only
// within this file and stay `private`.

extension GigCrateRepository {
    /// The crate roll-up, most-recently-performed first. `trackCount`,
    /// `cachedCount`, `stemsReadyCount` and `stemsBytes` come straight off
    /// `gig_crate_track`'s own columns (no join needed — `audioCached` and
    /// `stemsState` are stamped by this repository, not derived). Only
    /// `analyzedCount` needs a second, core-side lookup, since it is the one
    /// figure the DJ pool never held for a core track id.
    func fetchCrateRows() async throws -> [GigCrateRow] {
        let bases = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT gc.id, gc.name, gc.storageBudgetBytes, gc.lastPerformedAt,
                       gc.createdAt, COALESCE(p.title, '') AS playlistTitle,
                       COUNT(gct.id) AS trackCount,
                       COALESCE(SUM(CASE WHEN gct.audioCached THEN 1 ELSE 0 END), 0) AS cachedCount,
                       COALESCE(SUM(CASE WHEN gct.stemsState = 'ready' THEN 1 ELSE 0 END), 0) AS stemsReadyCount,
                       COALESCE(SUM(gct.stemsBytes), 0) AS stemsBytes
                FROM gig_crate gc
                LEFT JOIN playlist p ON p.id = gc.playlistID
                LEFT JOIN gig_crate_track gct ON gct.gigCrateID = gc.id
                GROUP BY gc.id
                ORDER BY gc.lastPerformedAt DESC NULLS FIRST, gc.createdAt DESC
                """)
        }
        var rows: [GigCrateRow] = []
        rows.reserveCapacity(bases.count)
        for row in bases {
            let crateID: Int64 = row["id"]
            let analyzedCount = try await analyzedCount(crateID: crateID)
            rows.append(GigCrateRow(id: crateID,
                                    name: row["name"],
                                    playlistTitle: row["playlistTitle"],
                                    trackCount: Int(row["trackCount"] as? Int64 ?? 0),
                                    cachedCount: Int(row["cachedCount"] as? Int64 ?? 0),
                                    analyzedCount: analyzedCount,
                                    stemsReadyCount: Int(row["stemsReadyCount"] as? Int64 ?? 0),
                                    stemsBytes: row["stemsBytes"] as? Int64 ?? 0,
                                    storageBudgetBytes: row["storageBudgetBytes"],
                                    lastPerformedAt: row["lastPerformedAt"],
                                    createdAt: row["createdAt"]))
        }
        return rows
    }

    /// How many of a crate's (core) track ids have a completed core analysis
    /// row — the core-side replacement for the old `t.analysisState =
    /// 'analyzed'` DJ-local join.
    private func analyzedCount(crateID: Int64) async throws -> Int {
        let trackIDs = try await pool.read { db in
            try GigCrateTrack.filter(Column("gigCrateID") == crateID).fetchAll(db).map(\.trackID)
        }
        guard !trackIDs.isEmpty else { return 0 }
        return try await library.dbQueue.read { db in
            try DiscoveryTrackAnalysis
                .filter(trackIDs.contains(Column("trackId")))
                .filter(Column("completedAt") != nil)
                .fetchCount(db)
        }
    }

    /// A crate's ordered track rows, resolved against the core `LibraryStore`
    /// (title/artist/duration) and the core `discovery_track_analysis` table
    /// (bpm/camelot/analysis state) — `gig_crate_track.trackID` is a core id
    /// since dj_v8, so the old `JOIN track t ON t.id = gct.trackID` against
    /// the DJ-local `track` table silently dropped every row (an INNER JOIN
    /// with no match). A core lookup miss (a track since deleted from the
    /// library) is skipped, mirroring `DeckLoader.rows(in: .playlist)`.
    func fetchTrackRows(crateID: Int64) async throws -> [GigCrateTrackRow] {
        let crateTracks = try await pool.read { db in
            try GigCrateTrack
                .filter(Column("gigCrateID") == crateID)
                .order(Column("position"))
                .fetchAll(db)
        }
        var rows: [GigCrateTrackRow] = []
        rows.reserveCapacity(crateTracks.count)
        for track in crateTracks {
            guard let core = try? await library.trackRow(id: track.trackID) else { continue }
            let analysis: DiscoveryTrackAnalysis? = (try? await library.dbQueue.read { db in
                try DiscoveryTrackAnalysis.fetchOne(db, key: track.trackID)
            }) ?? nil
            rows.append(GigCrateTrackRow(
                position: track.position,
                trackID: track.trackID,
                title: core.track.title,
                artistNames: core.artist?.name ?? core.album?.artist ?? "",
                durationSec: core.track.durationSec,
                bpm: analysis?.bpm,
                camelot: analysis?.key,
                audioCached: track.audioCached,
                stemsState: track.stemsState,
                stemsBytes: track.stemsBytes,
                analysisState: (analysis?.completedAt != nil) ? "analyzed" : "pending"))
        }
        return rows
    }

    /// The FR-LIB-8 gate at promotion/refresh time: audio is fully local and
    /// reachable — resolved against the core `LibraryStore` `Asset` for this
    /// (core) `trackID`, then a real file-exists probe. Mirrors `DeckLoader`'s
    /// `readiness(forCore:)`/`resolveAudioURL(for:)` so a crate never calls a
    /// partially-cached remote track ready (FR-LIB-8, §4.1).
    ///
    /// C02 fix (session 14): this used to look up a DJ-local `DJAsset` row by
    /// `trackID`, which was correct only while crate member ids were
    /// DJ-local. Since dj_v8 (session 13), `gig_crate_track.trackID` is a
    /// core `LibraryStore` id, so this must resolve through the core library
    /// instead — a DJ-local lookup now silently misses every track.
    func isAudioCached(trackID: Int64) async -> Bool {
        guard let row = try? await library.trackRow(id: trackID),
              let asset = row.asset,
              let url = Self.resolveAudioURL(for: asset) else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Resolves a core `Asset` to its local audio URL: a per-file bookmark, a
    /// direct file:// remote URL, or an app-relative path. Mirrors
    /// `DeckLoader.resolveAudioURL(for:)` / `PlaylistCrateImporter.localURL(for:)`
    /// — the other core-`Asset` resolvers in this codebase.
    private static func resolveAudioURL(for asset: Asset) -> URL? {
        if let bookmark = asset.bookmark, let (url, _) = BookmarkVault.resolve(bookmark) {
            return url
        }
        if let remote = asset.remoteURL.flatMap(URL.init(string:)), remote.isFileURL {
            return remote
        }
        if let relPath = asset.relPath,
           let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil,
                                                    create: false) {
            let url = base.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let remote = asset.remoteURL.flatMap(URL.init(string:)),
           AudioCache.completeCacheExists(for: remote) {
            return AudioCache.fileURL(for: AudioCache.key(for: remote))
        }
        return nil
    }
}
