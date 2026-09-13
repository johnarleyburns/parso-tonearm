import Foundation
import GRDB
import TonearmCore

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
///
/// The `gig_crate`/`gig_crate_track` records live in `GigCrateRecords.swift`,
/// the read models (`GigCrateRow`/`GigCrateTrackRow`/`GigCrateDetail`) in
/// `GigCrateReadModels.swift`, the mutation methods in
/// `GigCrateRepository+Mutations.swift`, and the core-catalog read helpers in
/// `GigCrateRepository+ReadHelpers.swift`.
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
}
