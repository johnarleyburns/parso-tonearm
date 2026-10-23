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
    public func recordBlendEdgePlan(_ plan: StarterEdgePlan, from fromKey: String, to toKey: String,
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

    public func blendCatalogEdgePlan(from fromKey: String, to toKey: String) throws -> StarterEdgePlan? {
        try dbQueue.read { db in
            try BlendCatalogEdge.filter(Column("fromKey") == fromKey && Column("toKey") == toKey).fetchOne(db)?.plan
        }
    }
}
