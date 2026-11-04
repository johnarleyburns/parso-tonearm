import Foundation
import GRDB

public enum BlendCatalogError: Error, Equatable {
    case unknownTrack(String)
    case illegalTransition(from: BlendCatalogState, to: BlendCatalogState)
    case missingFacts(String)
}

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

    /// Catalog tracks at or beyond `state`: the only ones a blend may select.
    public func blendCatalogTracks(atLeast state: BlendCatalogState = .blendEligible,
                                   packTag: String? = nil) throws -> [BlendCatalogTrack] {
        try dbQueue.read { db in
            var request = BlendCatalogTrack.order(Column("catalogKey"))
            if let packTag { request = request.filter(Column("packTag") == packTag) }
            return try request.fetchAll(db).filter { $0.state >= state }
        }
    }

    public func blendCatalogTrack(key: String) throws -> BlendCatalogTrack? {
        try dbQueue.read { try BlendCatalogTrack.fetchOne($0, key: key) }
    }

    /// Adds a track at `.unindexed`, keeping any state it already reached.
    public func registerBlendCatalogTrack(key: String, packTag: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            guard try BlendCatalogTrack.fetchOne(db, key: key) == nil else { return }
            try BlendCatalogTrack(catalogKey: key, packTag: packTag, state: .unindexed, durationSeconds: nil,
                                  bpm: nil, beatPeriod: nil, beatPhase: nil, rmsDB: nil, updatedAt: date).insert(db)
        }
    }

    /// `unindexed → blendEligible`, only with complete, valid facts.
    public func markBlendEligible(key: String, facts: StarterTrackFacts, traits: BlendTraits,
                                  sourceURL: String? = nil, analysisVersion: String? = nil,
                                  at date: Date = Date()) throws {
        guard facts.isBlendReady, traits.isValid else { throw BlendCatalogError.missingFacts(key) }
        try dbQueue.write { db in
            guard var row = try BlendCatalogTrack.fetchOne(db, key: key) else { throw BlendCatalogError.unknownTrack(key) }
            guard row.state.canAdvance(to: .blendEligible) else {
                throw BlendCatalogError.illegalTransition(from: row.state, to: .blendEligible)
            }
            row.state = .blendEligible
            row.durationSeconds = facts.durationSeconds; row.bpm = facts.bpm; row.beatPeriod = facts.beatPeriod
            row.beatPhase = facts.beatPhase; row.rmsDB = facts.rmsDB; row.updatedAt = date
            row.genre = traits.genre; row.subgenre = traits.subgenre; row.camelotKey = traits.camelotKey.uppercased()
            row.sourceURL = sourceURL ?? row.sourceURL; row.analysisVersion = analysisVersion ?? row.analysisVersion
            try row.update(db)
        }
    }

    /// Stores a concrete plan for `from → to`; both ends must be blend-eligible, and each moves to
    /// `edgePlanned`. Replacing an edge's plan keeps one row per pair.
    public func recordBlendEdgePlan(_ plan: BlendEdgePlan, from fromKey: String, to toKey: String,
                                    packTag: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            for key in [fromKey, toKey] {
                guard var row = try BlendCatalogTrack.fetchOne(db, key: key) else { throw BlendCatalogError.unknownTrack(key) }
                if row.state == .unindexed { throw BlendCatalogError.illegalTransition(from: .unindexed, to: .edgePlanned) }
                if row.state == .blendEligible { row.state = .edgePlanned; row.updatedAt = date; try row.update(db) }
            }
            try BlendCatalogEdge(fromKey: fromKey, toKey: toKey, packTag: packTag,
                                 planJSON: JSONEncoder().encode(plan)).save(db)
        }
    }

    public func blendCatalogEdgePlan(from fromKey: String, to toKey: String) throws -> BlendEdgePlan? {
        try dbQueue.read { db in
            try BlendCatalogEdge.filter(Column("fromKey") == fromKey && Column("toKey") == toKey).fetchOne(db)?.plan
        }
    }
}
