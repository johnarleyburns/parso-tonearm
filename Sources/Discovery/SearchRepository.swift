#if !os(watchOS)
import Foundation
import GRDB
import ParsoAudioAnalysis
import TonearmCore

/// The SQL side of unified retrieval (plan §9): scope resolution, eligibility
/// (revision/version + hard BPM/key), coverage state derivation and result
/// materialization to core `TrackRow` — never a `DJTrackRow` join.
///
/// Every ID set is produced by a predicate query, not a giant `IN (?, ?, …)`
/// bind list, so a 20,000-track scope never hits SQLite's variable limit
/// (plan §9). The only bounded `IN` is the final <=200-row materialization.
public struct SearchRepository: Sendable {
    private let reader: any DatabaseReader

    public init(reader: any DatabaseReader) {
        self.reader = reader
    }

    // MARK: - Scope

    /// A SQL `WHERE` fragment (against `track t`) plus its bound arguments for
    /// the query's selected scope. Returns `nil` when the scope is explicitly
    /// empty (caller returns `emptyScope`, never widening — plan §9).
    struct ScopeSQL {
        let whereClause: String
        let arguments: StatementArguments
    }

    static func scopeSQL(_ query: ValidatedQuery) -> ScopeSQL? {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let sourceIDs = query.sourceIDs {
            if sourceIDs.isEmpty { return nil }
            let placeholders = sourceIDs.map { _ in "?" }.joined(separator: ",")
            clauses.append("t.sourceId IN (\(placeholders))")
            args.append(contentsOf: sourceIDs)
        }
        if let playlistID = query.playlistID {
            clauses.append("t.id IN (SELECT trackId FROM playlist_item WHERE playlistId = ?)")
            args.append(playlistID)
        }
        let whereClause = clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
        return ScopeSQL(whereClause: whereClause, arguments: StatementArguments(args))
    }

    // MARK: - Coverage (plan §9)

    public struct Coverage: Equatable, Sendable {
        /// Distinct truthful response states — derived from the SELECTED scope
        /// BEFORE musical filters (plan §9).
        public enum State: Equatable, Sendable {
            case emptyLibrary
            case emptyScope
            case sourceUnavailable
            case zeroIndexed
            case indexingInProgress
            case ready
        }

        public var state: State
        /// Total tracks in the selected scope (before musical filters).
        public var totalInScope: Int
        /// Tracks in scope with a completed embedding row.
        public var indexed: Int
        /// Tracks in scope with an index job not yet complete.
        public var awaitingIndex: Int
        /// Tracks in scope whose job is parked waiting for an asset.
        public var waitingForAssets: Int
        /// Tracks in scope whose job failed / is unsupported.
        public var failedOrUnsupported: Int
        /// Tracks matching the hard BPM/key filters (0 when there are none).
        public var matchingHardFilters: Int?
    }

    /// Derive coverage for the query's scope. Throws on a real SQL error —
    /// never collapses to `(0, 0)` (plan §9).
    public func coverage(for query: ValidatedQuery, pipelineVersion: Int) throws -> Coverage {
        try reader.read { db in
            let libraryTotal = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? 0
            if libraryTotal == 0 {
                return Coverage(
                    state: .emptyLibrary, totalInScope: 0, indexed: 0, awaitingIndex: 0,
                    waitingForAssets: 0, failedOrUnsupported: 0, matchingHardFilters: nil)
            }
            guard let scope = Self.scopeSQL(query) else {
                return Coverage(
                    state: .emptyScope, totalInScope: 0, indexed: 0, awaitingIndex: 0,
                    waitingForAssets: 0, failedOrUnsupported: 0, matchingHardFilters: nil)
            }
            // A named source scope that resolves to no rows because the source
            // is gone is "source unavailable", distinct from an empty library.
            if let sourceIDs = query.sourceIDs, !sourceIDs.isEmpty {
                let placeholders = sourceIDs.map { _ in "?" }.joined(separator: ",")
                let liveSources = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM source WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(sourceIDs)) ?? 0
                if liveSources == 0 {
                    return Coverage(
                        state: .sourceUnavailable, totalInScope: 0, indexed: 0, awaitingIndex: 0,
                        waitingForAssets: 0, failedOrUnsupported: 0, matchingHardFilters: nil)
                }
            }

            let total = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM track t WHERE \(scope.whereClause)",
                arguments: scope.arguments) ?? 0

            let indexed = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM track t
                    JOIN discovery_embedding e ON e.trackId = t.id
                    WHERE \(scope.whereClause)
                    """,
                arguments: scope.arguments) ?? 0

            func jobCount(states: [String]) throws -> Int {
                let sp = states.map { _ in "?" }.joined(separator: ",")
                var a: [any DatabaseValueConvertible] = []
                if let sourceIDs = query.sourceIDs { a.append(contentsOf: sourceIDs) }
                if let playlistID = query.playlistID { a.append(playlistID) }
                a.append(pipelineVersion)
                a.append(contentsOf: states)
                return try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM track t
                        JOIN discovery_index_job j ON j.trackId = t.id
                        WHERE \(scope.whereClause) AND j.pipelineVersion = ?
                          AND j.state IN (\(sp))
                        """,
                    arguments: StatementArguments(a)) ?? 0
            }

            let awaiting = try jobCount(states: [
                "queued", "running", "waitingForModel", "waitingForNetwork",
                "waitingForPower", "waitingForCooling", "retryScheduled",
            ])
            let waitingAssets = try jobCount(states: ["waitingForAsset"])
            let failed = try jobCount(states: ["failed", "unsupported"])

            var matching: Int?
            if query.hasHardMusicalFilter {
                let (clause, hardArgs) = Self.hardFilterClause(query)
                var a: [any DatabaseValueConvertible] = []
                if let sourceIDs = query.sourceIDs { a.append(contentsOf: sourceIDs) }
                if let playlistID = query.playlistID { a.append(playlistID) }
                a.append(contentsOf: hardArgs)
                matching = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM track t
                        JOIN discovery_track_analysis a ON a.trackId = t.id
                        WHERE \(scope.whereClause) AND \(clause)
                        """,
                    arguments: StatementArguments(a)) ?? 0
            }

            let state: Coverage.State
            if indexed == 0 && awaiting == 0 && failed == 0 {
                state = .zeroIndexed
            } else if awaiting > 0 {
                state = .indexingInProgress
            } else {
                state = .ready
            }

            return Coverage(
                state: state, totalInScope: total, indexed: indexed, awaitingIndex: awaiting,
                waitingForAssets: waitingAssets, failedOrUnsupported: failed,
                matchingHardFilters: matching)
        }
    }

    // MARK: - Eligible ID sets

    /// Track IDs in scope that also satisfy the hard BPM/key gates (if any).
    /// Unknown required attributes are excluded (plan §9: "Hard musical
    /// filters exclude unknown required attributes"). Predicate-only — safe
    /// for a 20,000-row scope.
    public func eligibleTrackIDs(
        for query: ValidatedQuery,
        musicalMatch: MusicalMatchReference? = nil
    ) throws -> Set<Int64> {
        try reader.read { db in
            guard let scope = Self.scopeSQL(query) else { return [] }
            var sql = "SELECT t.id FROM track t"
            var args: [any DatabaseValueConvertible] = []
            if let sourceIDs = query.sourceIDs { args.append(contentsOf: sourceIDs) }
            if let playlistID = query.playlistID { args.append(playlistID) }

            if query.hasHardMusicalFilter || musicalMatch != nil {
                let (clause, hardArgs) = Self.hardFilterClause(query, musicalMatch: musicalMatch)
                sql += " JOIN discovery_track_analysis a ON a.trackId = t.id"
                sql += " WHERE \(scope.whereClause) AND \(clause)"
                args.append(contentsOf: hardArgs)
            } else {
                sql += " WHERE \(scope.whereClause)"
            }
            let ids = try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return Set(ids)
        }
    }

    private static func hardFilterClause(
        _ query: ValidatedQuery,
        musicalMatch: MusicalMatchReference? = nil
    ) -> (String, [any DatabaseValueConvertible]) {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []
        if let range = query.bpmRange {
            clauses.append("a.bpm IS NOT NULL AND a.bpm BETWEEN ? AND ?")
            args.append(range.lowerBound)
            args.append(range.upperBound)
        }
        if let key = query.compatibleKey {
            let codes = Camelot.compatible(key).map(\.code).sorted()
            let sp = codes.map { _ in "?" }.joined(separator: ",")
            clauses.append("a.key IS NOT NULL AND a.key IN (\(sp))")
            args.append(contentsOf: codes)
        }
        if let musicalMatch {
            guard let range = MusicalMatchPolicy.bpmRange(for: musicalMatch.bpm) else {
                return ("0", [])
            }
            clauses.append("a.bpm IS NOT NULL AND a.bpm BETWEEN ? AND ?")
            args.append(range.lowerBound)
            args.append(range.upperBound)
            let codes = MusicalMatchPolicy.compatibleKeyCodes(for: musicalMatch.camelot).sorted()
            let sp = codes.map { _ in "?" }.joined(separator: ",")
            clauses.append("a.key IS NOT NULL AND a.key IN (\(sp))")
            args.append(contentsOf: codes)
        }
        return (clauses.isEmpty ? "1" : clauses.joined(separator: " AND "), args)
    }

    // MARK: - Musical attributes for hybrid scoring

    public struct TrackAttributes: Sendable, Equatable {
        public var bpm: Double?
        public var camelot: CamelotKey?
        public var energy: Double?
        public var phraseLength: Double?
    }

    /// Analysis attributes for a set of track IDs, for the hybrid re-rank.
    /// Predicate join over the analysis table — no bind-list explosion.
    public func attributes(pipelineVersion: Int) throws -> [Int64: TrackAttributes] {
        try reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT trackId, bpm, key, energy FROM discovery_track_analysis
                    WHERE analysisVersion = ?
                    """,
                arguments: [pipelineVersion])
            var out: [Int64: TrackAttributes] = [:]
            for row in rows {
                let id: Int64 = row["trackId"]
                out[id] = TrackAttributes(
                    bpm: row["bpm"],
                    camelot: (row["key"] as String?).flatMap(CamelotKey.init(code:)),
                    energy: row["energy"],
                    phraseLength: nil)
            }
            return out
        }
    }

    // MARK: - Filter-only / browse ordering

    /// Scope rows ordered by core `sortKey` then track id — the stable order
    /// for filter-only and empty-text browse (plan §9). No fabricated
    /// semantic score.
    public func orderedScopeRows(
        for query: ValidatedQuery, applyHardFilters: Bool, limit: Int
    ) throws -> [TrackRow] {
        let ids: [Int64] = try reader.read { db in
            guard let scope = Self.scopeSQL(query) else { return [] }
            var sql = "SELECT t.id FROM track t"
            var args: [any DatabaseValueConvertible] = []
            if let sourceIDs = query.sourceIDs { args.append(contentsOf: sourceIDs) }
            if let playlistID = query.playlistID { args.append(playlistID) }
            if applyHardFilters && query.hasHardMusicalFilter {
                let (clause, hardArgs) = Self.hardFilterClause(query)
                sql += " JOIN discovery_track_analysis a ON a.trackId = t.id"
                sql += " WHERE \(scope.whereClause) AND \(clause)"
                args.append(contentsOf: hardArgs)
            } else {
                sql += " WHERE \(scope.whereClause)"
            }
            sql += " ORDER BY t.sortKey ASC, t.id ASC LIMIT ?"
            args.append(limit)
            return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
        return try materialize(ids)
    }

    // MARK: - Materialization (bounded IN, <=200 ids)

    /// Fetch full `TrackRow`s for the ranked ids, preserving the given order,
    /// and validating each still exists (plan §8: "validate live IDs/revisions
    /// before materialization").
    public func materialize(_ ids: [Int64]) throws -> [TrackRow] {
        guard !ids.isEmpty else { return [] }
        return try reader.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let tracks = try Track.fetchAll(
                db, sql: "SELECT * FROM track WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids))
            var trackByID: [Int64: Track] = [:]
            for t in tracks { if let id = t.id { trackByID[id] = t } }

            let albumIDs = Array(Set(tracks.compactMap(\.albumId)))
            let sourceIDList = Array(Set(tracks.map(\.sourceId)))
            let artistIDs = Array(Set(tracks.compactMap(\.artistId)))

            func inClause(_ count: Int) -> String {
                Array(repeating: "?", count: count).joined(separator: ",")
            }
            var albums: [Int64: Album] = [:]
            if !albumIDs.isEmpty {
                for a in try Album.fetchAll(
                    db, sql: "SELECT * FROM album WHERE id IN (\(inClause(albumIDs.count)))",
                    arguments: StatementArguments(albumIDs)) where a.id != nil {
                    albums[a.id!] = a
                }
            }
            var sources: [Int64: Source] = [:]
            if !sourceIDList.isEmpty {
                for s in try Source.fetchAll(
                    db, sql: "SELECT * FROM source WHERE id IN (\(inClause(sourceIDList.count)))",
                    arguments: StatementArguments(sourceIDList)) where s.id != nil {
                    sources[s.id!] = s
                }
            }
            var artists: [Int64: Artist] = [:]
            if !artistIDs.isEmpty {
                for a in try Artist.fetchAll(
                    db, sql: "SELECT * FROM artist WHERE id IN (\(inClause(artistIDs.count)))",
                    arguments: StatementArguments(artistIDs)) where a.id != nil {
                    artists[a.id!] = a
                }
            }

            let assets = try Asset.fetchAll(
                db, sql: "SELECT * FROM asset WHERE trackId IN (\(placeholders))",
                arguments: StatementArguments(ids))
            var assetByTrack: [Int64: Asset] = [:]
            for a in assets where assetByTrack[a.trackId] == nil { assetByTrack[a.trackId] = a }

            return ids.compactMap { id -> TrackRow? in
                guard let track = trackByID[id] else { return nil }
                return TrackRow(
                    track: track,
                    album: track.albumId.flatMap { albums[$0] },
                    source: sources[track.sourceId],
                    asset: assetByTrack[id],
                    artist: track.artistId.flatMap { artists[$0] })
            }
        }
    }

    /// The reference track's own attributes, for a similar-track query's
    /// `RankTarget` (plan §9: "Similar-track queries may use valid reference
    /// attributes").
    public func referenceAttributes(trackID: Int64, pipelineVersion: Int) throws -> TrackAttributes? {
        try attributes(pipelineVersion: pipelineVersion)[trackID]
    }

    public func trackExists(_ id: Int64) throws -> Bool {
        try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM track WHERE id = ?", arguments: [id]) != nil
        }
    }
}
#endif
