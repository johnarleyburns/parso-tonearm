import Foundation
import GRDB

extension LibraryStore {
    /// Gives every pre-v38 row an explicit source: every row is an ordinary Jamendo track, whose old
    /// `sourceURL` is demoted to refreshable cache data — unless it is a GitHub Release URL (the
    /// retired pinned Starter asset mirror), which is never a valid Jamendo stream and is dropped.
    static func backfillCatalogSources(_ db: Database) throws {
        for var row in try BlendCatalogTrack.fetchAll(db) where row.sourceKind == nil {
            row.sourceKind = .jamendo
            // `catalogID`-derived can itself be empty (e.g. a bare "jamendo-" with nothing after
            // it survives the replace unchanged) — nil, not "", so it falls back to `trackID` the
            // same way a row with no catalogID at all already does (v41 repairs any "" this wrote
            // before this guard existed).
            let fromCatalogID = row.catalogID?.replacingOccurrences(of: "jamendo-", with: "")
            row.providerTrackID = (fromCatalogID?.isEmpty == false ? fromCatalogID : nil) ?? row.trackID
            if let old = row.sourceURL, let url = URL(string: old), url.scheme?.hasPrefix("http") == true,
               url.host != "github.com" {
                row.cachedURL = old
            }
            try row.update(db)
        }
    }

    /// Repairs rows the v38 backfill above left with an explicit empty `providerTrackID` instead
    /// of nil, before the guard against that was added. A real report: `audioLocator()` correctly
    /// treats "" as corrupt data, distinct from the legitimate "never stored" nil case, and
    /// rejects it rather than silently falling back — so a persisted queue whose current track
    /// was exactly such a row failed to resolve on every single launch (restorePersistedQueue()
    /// always calls loadCurrent for it), with a "Jamendo track unavailable" toast that could never
    /// clear on its own. v38 itself can't be edited to fix already-applied installs — migrations
    /// never re-run — so this runs once, separately, as v41. Clearing back to nil lets the
    /// existing, correct fallback-to-trackID logic take over, exactly as it already does for rows
    /// that were nil all along.
    static func repairEmptyProviderTrackIDs(_ db: Database) throws {
        for var row in try BlendCatalogTrack.filter(Column("providerTrackID") == "").fetchAll(db) {
            row.providerTrackID = nil
            try row.update(db)
        }
    }

    /// Adds a general catalog track (provider `jamendo`, stable ID) at `.unindexed`, keeping any row it has.
    public func upsertJamendoCatalogTrack(trackID: String, cachedURL: URL?,
                                          expiry: Date? = nil, at date: Date = Date()) throws {
        guard !trackID.isEmpty else { return }
        try dbQueue.write { db in
            let key = BlendCatalogTrack.jamendoKey(trackID: trackID)
            var row = try BlendCatalogTrack.fetchOne(db, key: key)
                ?? BlendCatalogTrack(catalogKey: key, packTag: BlendCatalogTrack.jamendoPackTag,
                                     state: .unindexed, durationSeconds: nil, bpm: nil, beatPeriod: nil,
                                     beatPhase: nil, rmsDB: nil, updatedAt: date)
            row.sourceKind = .jamendo
            row.providerTrackID = trackID
            if let cachedURL {
                row.cachedURL = cachedURL.absoluteString
                row.cachedURLExpiry = expiry
            }
            row.updatedAt = date
            try row.save(db)
        }
    }

    /// Persists a refreshed Jamendo stream URL (cache data) for a Jamendo row; a no-op for any other row.
    public func updateCachedLocator(key: String, url: URL, expiry: Date?) throws {
        try dbQueue.write { db in
            guard var row = try BlendCatalogTrack.fetchOne(db, key: key), row.sourceKind == .jamendo else { return }
            row.cachedURL = url.absoluteString
            row.cachedURLExpiry = expiry
            try row.update(db)
        }
    }

    public func blendCatalogTrack(key: String) throws -> BlendCatalogTrack? {
        try dbQueue.read { try BlendCatalogTrack.fetchOne($0, key: key) }
    }
}
