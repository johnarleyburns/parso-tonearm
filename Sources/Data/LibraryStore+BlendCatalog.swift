import Foundation
import GRDB

public enum BlendCatalogError: Error, Equatable {
    case unknownTrack(String)
    case illegalTransition(from: BlendCatalogState, to: BlendCatalogState)
    case missingFacts(String)
}

extension LibraryStore {
    /// Resolves the pack's tracks from the versioned starter catalog (`starter-v4.sqlite`) and stores
    /// catalog id, genre, duration, BPM, Camelot key and provenance for each. Idempotent; the v36
    /// migration calls it so a fresh install already holds the catalog (no download, no model).
    /// Every id is validated before anything is written, so a bad catalog changes nothing. Beat grid,
    /// phase and loudness are not in the catalog and are never invented: a new row stays `.unindexed`
    /// until normal indexing supplies them, and an existing row keeps the state and grid it reached.
    static func seedStarterCatalog(_ db: Database, pack: StarterBlendPack = .v1, now: Date = Date(),
                                   catalog: StarterCatalogAdapter? = nil) throws {
        let adapter = try catalog ?? StarterCatalogAdapter.bundled()
        let entries = try adapter.resolve(trackIDs: StarterBlendCatalog.blends.flatMap(\.trackIDs))
        let provenance = "starter-v4:\(try adapter.contentVersion())"
        try db.inSavepoint {
            try writeStarterCatalog(db, entries: entries, pack: pack, now: now, provenance: provenance)
            return .commit
        }
    }

    /// The writes of `seedStarterCatalog`, run inside one savepoint so a failure leaves nothing behind.
    private static func writeStarterCatalog(_ db: Database, entries: [StarterCatalogEntry], pack: StarterBlendPack,
                                            now: Date, provenance: String) throws {
        for entry in entries {
            // Only mirrored Starter assets have a Release URL; other catalog IDs are never seeded here.
            guard let assetURL = pack.assetURL(trackID: entry.trackID) else { continue }
            let key = BlendCatalogTrack.key(pack: pack, trackID: entry.trackID)
            var record = try BlendCatalogTrack.fetchOne(db, key: key)
                ?? BlendCatalogTrack(catalogKey: key, packTag: pack.releaseTag, state: .unindexed, durationSeconds: nil,
                                     bpm: nil, beatPeriod: nil, beatPhase: nil, rmsDB: nil, updatedAt: now)
            record.packTag = pack.releaseTag
            record.durationSeconds = entry.durationSeconds
            record.bpm = entry.bpm
            record.genre = entry.genre
            record.subgenre = nil
            record.camelotKey = entry.camelot
            record.catalogID = entry.catalogID
            record.sourceURL = assetURL.absoluteString
            record.sourceKind = .starterRelease
            record.providerTrackID = nil
            record.cachedURL = nil
            record.cachedURLExpiry = nil
            record.analysisVersion = provenance
            record.updatedAt = now
            try record.save(db)
        }
        for plan in StarterBlendRuntimeData.edges {
            try BlendCatalogEdge(fromKey: BlendCatalogTrack.key(pack: pack, trackID: plan.outgoingTrackID),
                                 toKey: BlendCatalogTrack.key(pack: pack, trackID: plan.incomingTrackID),
                                 packTag: pack.releaseTag, planJSON: JSONEncoder().encode(plan)).save(db)
        }
    }

    /// Gives every pre-v38 row an explicit source: mirrored Starter assets become `.starterRelease`; any
    /// other row is a Jamendo track whose old `sourceURL` is demoted to refreshable cache data (a
    /// GitHub Release URL is dropped, never kept as a Jamendo locator).
    static func backfillCatalogSources(_ db: Database, pack: StarterBlendPack = .v1) throws {
        for var row in try BlendCatalogTrack.fetchAll(db) where row.sourceKind == nil {
            if row.packTag == pack.releaseTag, pack.contains(trackID: row.trackID) {
                row.sourceKind = .starterRelease
            } else {
                row.sourceKind = .jamendo
                row.providerTrackID = row.catalogID?.replacingOccurrences(of: "jamendo-", with: "") ?? row.trackID
                if let old = row.sourceURL, !pack.owns(URL(string: old) ?? URL(fileURLWithPath: "/")),
                   URL(string: old)?.scheme?.hasPrefix("http") == true { row.cachedURL = old }
            }
            try row.update(db)
        }
    }

    /// Adds a general catalog track (provider `jamendo`, stable ID) at `.unindexed`, keeping any row it has.
    /// A Starter Pack ID is never registered this way: it has only its pinned Release asset.
    public func registerJamendoCatalogTrack(trackID: String, at date: Date = Date()) throws {
        guard !trackID.isEmpty, !StarterBlendPack.v1.contains(trackID: trackID) else { return }
        try dbQueue.write { db in
            let key = BlendCatalogTrack.jamendoKey(trackID: trackID)
            guard try BlendCatalogTrack.fetchOne(db, key: key) == nil else { return }
            var row = BlendCatalogTrack(catalogKey: key, packTag: BlendCatalogTrack.jamendoPackTag, state: .unindexed,
                                        durationSeconds: nil, bpm: nil, beatPeriod: nil, beatPhase: nil, rmsDB: nil,
                                        updatedAt: date)
            row.sourceKind = .jamendo
            row.providerTrackID = trackID
            try row.insert(db)
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
