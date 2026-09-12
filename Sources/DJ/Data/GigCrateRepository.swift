import Foundation
import GRDB
import TonearmCore

// MARK: - Records (§14.3)

/// A `gig_crate` row (§14.3, FR-PLIST-9): a playlist promoted to performance
/// readiness — audio cached, stage-3 stems queued, all under a storage budget.
public struct GigCrate: Codable, Identifiable, FetchableRecord,
                        MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var name: String
    public var playlistID: Int64?
    public var smartCrateID: Int64?
    /// This crate's own stem-budget ceiling (§14.3, §43.6).
    public var storageBudgetBytes: Int64
    /// Drives LRU eviction (FR-ANL-9) — set when the crate is performed.
    public var lastPerformedAt: Date?
    public var createdAt: Date

    public init(id: Int64? = nil,
                syncID: String,
                name: String,
                playlistID: Int64? = nil,
                smartCrateID: Int64? = nil,
                storageBudgetBytes: Int64,
                lastPerformedAt: Date? = nil,
                createdAt: Date) {
        self.id = id
        self.syncID = syncID
        self.name = name
        self.playlistID = playlistID
        self.smartCrateID = smartCrateID
        self.storageBudgetBytes = storageBudgetBytes
        self.lastPerformedAt = lastPerformedAt
        self.createdAt = createdAt
    }

    public static let databaseTableName = "gig_crate"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The per-track stem states (`gig_crate_track.stemsState`, §14.3).
public enum GigCrateStemsState: String, Sendable, Equatable {
    case pending
    case running
    case ready
    case failed
    /// The crate's stems were evicted by the storage budget (§43.6); the full
    /// mix still plays and the track is re-queued on the next prepare.
    case evicted
}

/// A `gig_crate_track` row (§14.3): one track of a prepared crate with its
/// FR-LIB-8 audio-cached flag and stage-3 stem roll-up.
public struct GigCrateTrack: Codable, Identifiable, FetchableRecord,
                             MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var gigCrateID: Int64
    public var trackID: Int64
    public var position: Int
    /// FR-LIB-8: the audio is fully local and reachable. Set at promotion and
    /// refreshed as remote caching progresses; a deck never waits on a network.
    public var audioCached: Bool
    /// `pending|running|ready|failed|evicted` (§14.3).
    public var stemsState: String
    public var stemsBytes: Int64

    public init(id: Int64? = nil,
                gigCrateID: Int64,
                trackID: Int64,
                position: Int,
                audioCached: Bool = false,
                stemsState: String = GigCrateStemsState.pending.rawValue,
                stemsBytes: Int64 = 0) {
        self.id = id
        self.gigCrateID = gigCrateID
        self.trackID = trackID
        self.position = position
        self.audioCached = audioCached
        self.stemsState = stemsState
        self.stemsBytes = stemsBytes
    }

    public static let databaseTableName = "gig_crate_track"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Read models

/// A gig crate as the list surface renders it (§41.17, mockup `ipad/14`): the
/// crate joined with its per-track roll-up — cached / analyzed / stems-ready
/// counts and the on-disk stem bytes the §43.6 budget accounts.
public struct GigCrateRow: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let playlistTitle: String
    public let trackCount: Int
    public let cachedCount: Int
    public let analyzedCount: Int
    public let stemsReadyCount: Int
    /// The crate's on-disk stem bytes (the SUM of `gig_crate_track.stemsBytes`).
    public let stemsBytes: Int64
    public let storageBudgetBytes: Int64
    public let lastPerformedAt: Date?
    public let createdAt: Date

    public init(id: Int64, name: String, playlistTitle: String,
                trackCount: Int, cachedCount: Int, analyzedCount: Int,
                stemsReadyCount: Int, stemsBytes: Int64,
                storageBudgetBytes: Int64, lastPerformedAt: Date?, createdAt: Date) {
        self.id = id
        self.name = name
        self.playlistTitle = playlistTitle
        self.trackCount = trackCount
        self.cachedCount = cachedCount
        self.analyzedCount = analyzedCount
        self.stemsReadyCount = stemsReadyCount
        self.stemsBytes = stemsBytes
        self.storageBudgetBytes = storageBudgetBytes
        self.lastPerformedAt = lastPerformedAt
        self.createdAt = createdAt
    }

    /// FR-PLIST-9 readiness: every track's audio is local. Empty crates are
    /// never "ready" (there is nothing to perform).
    public var isReady: Bool { trackCount > 0 && cachedCount == trackCount }

    /// The stems-separated fraction for the header progress bar.
    public var stemsFraction: Double {
        guard trackCount > 0 else { return 0 }
        return Double(stemsReadyCount) / Double(trackCount)
    }
}

/// One track row of a gig crate (§41.17): the `gig_crate_track` row joined with
/// the track's display metadata and analysis state, so the surface never needs
/// an N+1 object graph. `audioCached` is the FR-LIB-8 flag; a track that is not
/// cached is honestly deck-disabled, never presented as ready.
public struct GigCrateTrackRow: Identifiable, Sendable, Equatable {
    public var id: Int64 { trackID }
    public let position: Int
    public let trackID: Int64
    public let title: String
    public let artistNames: String
    public let durationSec: Double?
    public let bpm: Double?
    public let camelot: String?
    /// FR-LIB-8: audio fully local and reachable.
    public let audioCached: Bool
    /// `pending|running|ready|failed|evicted`.
    public let stemsState: String
    public let stemsBytes: Int64
    /// `pending|analyzed|failed` — the stage-1 readout.
    public let analysisState: String

    public init(position: Int, trackID: Int64, title: String, artistNames: String,
                durationSec: Double?, bpm: Double?, camelot: String?,
                audioCached: Bool, stemsState: String, stemsBytes: Int64,
                analysisState: String) {
        self.position = position
        self.trackID = trackID
        self.title = title
        self.artistNames = artistNames
        self.durationSec = durationSec
        self.bpm = bpm
        self.camelot = camelot
        self.audioCached = audioCached
        self.stemsState = stemsState
        self.stemsBytes = stemsBytes
        self.analysisState = analysisState
    }

    /// The crate's derived stem state enum, for switch-friendly UI.
    public var stems: GigCrateStemsState {
        GigCrateStemsState(rawValue: stemsState) ?? .pending
    }
}

/// The full read model for one crate (§41.17): the crate row + its ordered
/// track rows + the per-crate roll-up the four header cards render.
public struct GigCrateDetail: Identifiable, Sendable, Equatable {
    public var id: Int64 { crate.id ?? 0 }
    public let crate: GigCrate
    public let playlistTitle: String
    public let tracks: [GigCrateTrackRow]

    public init(crate: GigCrate, playlistTitle: String, tracks: [GigCrateTrackRow]) {
        self.crate = crate
        self.playlistTitle = playlistTitle
        self.tracks = tracks
    }

    public var trackCount: Int { tracks.count }
    public var cachedCount: Int { tracks.lazy.filter(\.audioCached).count }
    public var analyzedCount: Int {
        tracks.lazy.filter { $0.analysisState == "analyzed" }.count
    }
    public var stemsReadyCount: Int {
        tracks.lazy.filter { $0.stems == .ready }.count
    }
    /// The stems-separated fraction for the header progress bar.
    public var stemsFraction: Double {
        guard trackCount > 0 else { return 0 }
        return Double(stemsReadyCount) / Double(trackCount)
    }
    /// The crate's on-disk stem bytes (the §43.6 account).
    public var stemsBytes: Int64 { tracks.reduce(0) { $0 + $1.stemsBytes } }
    /// The projected stem bytes this crate will consume once every pending
    /// track is separated — the "Storage for this crate" card (§43.6's
    /// ~13 MB/track figure).
    public var projectedStemBytes: Int64 {
        stemsBytes + Int64(tracks.lazy.filter { $0.stems != .ready }.count)
            * StorageBudgetService.estimatedStemsBytesPerTrack
    }
}

// MARK: - Repository

public enum GigCrateError: Error, LocalizedError {
    case persistFailed
    case crateNotFound

    public var errorDescription: String? {
        switch self {
        case .persistFailed: return "Could not create the gig crate"
        case .crateNotFound: return "This gig crate is no longer in the library"
        }
    }
}

/// The gig-crate data seam (§41.17, FR-PLIST-9): promotion from a playlist,
/// per-track readiness, the LRU + budget queries the §43.6 eviction needs.
/// Reads go straight through the pool; every promotion/mutation is one GRDB
/// transaction so a crash leaves either the whole crate or none (NFR-REL-1).
public struct GigCrateRepository: Sendable {
    public let pool: DatabasePool
    /// The one core music catalog (plan §3). Crate member rows
    /// (`gig_crate_track.trackID`, copied from `playlist_item`) are core
    /// `LibraryStore` track ids since dj_v8 — the FR-LIB-8 `audioCached` gate
    /// resolves them here, not against the DJ-local `DJAsset` table (C02
    /// follow-up; see session 13/14 notes in IMPLEMENTATION_STATUS.md).
    public let library: LibraryStore

    public init(pool: DatabasePool, library: LibraryStore = .shared) {
        self.pool = pool
        self.library = library
    }

    // MARK: - Promotion (FR-PLIST-9)

    /// Promote a static playlist to a gig crate: create the `gig_crate` row and
    /// copy the playlist's ordered items into `gig_crate_track` in ONE
    /// transaction, stamping each track's FR-LIB-8 `audioCached` flag at
    /// promotion time. Returns the new crate id.
    ///
    /// C02: each item's `trackID` is a core `LibraryStore` id, so the
    /// FR-LIB-8 cache probe is resolved against the core library (an actor,
    /// so it runs BEFORE the synchronous DJ-pool transaction that writes the
    /// crate rows) instead of a DJ-local `DJAsset` lookup.
    @discardableResult
    public func promote(playlistID: Int64,
                        name: String,
                        storageBudgetBytes: Int64) async throws -> Int64 {
        let items = try await pool.read { db in
            try DJPlaylistItem
                .filter(Column("playlistID") == playlistID)
                .order(Column("position"))
                .fetchAll(db)
        }
        var cachedByTrackIDBuilder: [Int64: Bool] = [:]
        for item in items {
            cachedByTrackIDBuilder[item.trackID] = await isAudioCached(trackID: item.trackID)
        }
        let cachedByTrackID = cachedByTrackIDBuilder
        return try await pool.write { db in
            var crate = GigCrate(syncID: UUID().uuidString,
                                 name: name,
                                 playlistID: playlistID,
                                 storageBudgetBytes: storageBudgetBytes,
                                 createdAt: Date())
            try crate.insert(db)
            guard let crateID = crate.id else { throw GigCrateError.persistFailed }

            for item in items {
                var row = GigCrateTrack(gigCrateID: crateID,
                                        trackID: item.trackID,
                                        position: item.position,
                                        audioCached: cachedByTrackID[item.trackID] ?? false)
                try row.insert(db)
            }
            return crateID
        }
    }

    // MARK: - Lists

    /// Every crate with its roll-up, most-recently-performed first — the list
    /// surface and the "Making room" panel both read this (§41.17).
    public func crates() async throws -> [GigCrateRow] {
        try await fetchCrateRows()
    }

    /// One crate's detail: the row + its ordered track rows.
    public func detail(crateID: Int64) async throws -> GigCrateDetail? {
        guard let crate = try await pool.read({ db in try GigCrate.fetchOne(db, key: crateID) }) else {
            return nil
        }
        let playlistTitle = try await pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT COALESCE(p.title, '') FROM playlist p WHERE p.id = ?
                """, arguments: [crate.playlistID ?? 0]) ?? ""
        }
        let tracks = try await fetchTrackRows(crateID: crateID)
        return GigCrateDetail(crate: crate, playlistTitle: playlistTitle, tracks: tracks)
    }

    /// A crate's track rows in stored order.
    public func trackRows(crateID: Int64) async throws -> [GigCrateTrackRow] {
        try await fetchTrackRows(crateID: crateID)
    }

    /// The crate's tracks whose stems are not ready (`pending|failed|evicted`),
    /// in stored order — the §36.3 lane's queue. Empty when none remain.
    public func tracksNeedingStems(crateID: Int64) throws -> [GigCrateTrack] {
        try pool.read { db in
            try GigCrateTrack
                .filter(Column("gigCrateID") == crateID
                        && Column("stemsState") != GigCrateStemsState.ready.rawValue)
                .order(Column("position"))
                .fetchAll(db)
        }
    }

    /// How many crate tracks still need stems — the reconcile count (§36.3).
    public func tracksNeedingStemsCount(crateID: Int64) throws -> Int {
        try tracksNeedingStems(crateID: crateID).count
    }

    /// All crates' stem usage, oldest-performed first — the LRU eviction
    /// ordering (§43.6, FR-ANL-9). `excluding` are never candidates.
    public func cratesByLRU(excluding protectedIDs: Set<Int64> = []) async throws -> [GigCrateRow] {
        let rows = try await fetchCrateRows()
        return rows
            .filter { !protectedIDs.contains($0.id) }
            .sorted { l, r in
                let lDate = l.lastPerformedAt ?? .distantPast
                let rDate = r.lastPerformedAt ?? .distantPast
                return lDate < rDate
            }
    }

    /// The crates whose stems are on disk (`stemsBytes > 0`), oldest first —
     /// the only set the budget can reclaim.
    public func evictableCrates(excluding protectedIDs: Set<Int64> = []) async throws -> [GigCrateRow] {
        try await cratesByLRU(excluding: protectedIDs).filter { $0.stemsBytes > 0 }
    }

    // MARK: - Mutations

    /// Mark a crate performed (§14.3 `lastPerformedAt`): called when the crate
    /// is opened in the workspace. This is the LRU clock FR-ANL-9 evicts by.
    public func markPerformed(crateID: Int64, at date: Date = Date()) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE gig_crate SET lastPerformedAt = ? WHERE id = ?
                """, arguments: [date, crateID])
        }
    }

    /// Set one crate track's stem state + on-disk bytes (§36.4 roll-up). The
    /// §36.3 lane writes `running` before separating and `ready`/`failed` after.
    public func setStemsState(crateID: Int64, trackID: Int64,
                              state: GigCrateStemsState, bytes: Int64 = 0) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE gig_crate_track SET stemsState = ?, stemsBytes = ?
                WHERE gigCrateID = ? AND trackID = ?
                """, arguments: [state.rawValue, bytes, crateID, trackID])
        }
    }

    /// Refresh a track's FR-LIB-8 flag as remote caching progresses (5.6's
    /// cache lane). Never un-pins a file that is present.
    public func setAudioCached(crateID: Int64, trackID: Int64, cached: Bool) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE gig_crate_track SET audioCached = ?
                WHERE gigCrateID = ? AND trackID = ?
                """, arguments: [cached, crateID, trackID])
        }
    }

    /// Re-stamp every crate track's FR-LIB-8 flag from the current disk state —
     /// the honest refresh after a cache purge or a completed download.
    public func refreshAudioCached(crateID: Int64) async throws {
        let rows = try await pool.read { db in
            try GigCrateTrack
                .filter(Column("gigCrateID") == crateID)
                .fetchAll(db)
        }
        var cachedByTrackIDBuilder: [Int64: Bool] = [:]
        for row in rows {
            cachedByTrackIDBuilder[row.trackID] = await isAudioCached(trackID: row.trackID)
        }
        let cachedByTrackID = cachedByTrackIDBuilder
        try await pool.write { db in
            for var row in rows {
                row.audioCached = cachedByTrackID[row.trackID] ?? false
                try row.update(db)
            }
        }
    }

    // MARK: - Read helpers (C02: crate members are core track ids)

    /// The crate roll-up, most-recently-performed first. `trackCount`,
    /// `cachedCount`, `stemsReadyCount` and `stemsBytes` come straight off
    /// `gig_crate_track`'s own columns (no join needed — `audioCached` and
    /// `stemsState` are stamped by this repository, not derived). Only
    /// `analyzedCount` needs a second, core-side lookup, since it is the one
    /// figure the DJ pool never held for a core track id.
    private func fetchCrateRows() async throws -> [GigCrateRow] {
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
    private func fetchTrackRows(crateID: Int64) async throws -> [GigCrateTrackRow] {
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
    private func isAudioCached(trackID: Int64) async -> Bool {
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
