import Foundation
import GRDB

/// A natural-language vibe query plus refinement and musical constraints
/// (§10.5, §16.5, App. G.5). Codable so a saved query round-trips through
/// `smart_crate.queryJSON` (§14, commit 2.5).
public struct VibeQuery: Sendable, Codable, Equatable {
    public var text: String
    /// "+ hypnotic" — additive terms nudge the semantic anchor toward them.
    public var positiveTerms: [String]
    /// "− cheesy" — subtractive terms push the anchor away.
    public var negativeTerms: [String]
    /// Stored as lo/hi so the type stays Codable (a `ClosedRange` is not).
    public var bpmLo: Double?
    public var bpmHi: Double?
    /// "Compatible with Deck A · 8A" — a hard Camelot gate plus a soft `keyFit`.
    public var compatibleWithKey: CamelotKey?
    public var limit: Int

    public init(text: String,
                positiveTerms: [String] = [],
                negativeTerms: [String] = [],
                bpmRange: ClosedRange<Double>? = nil,
                compatibleWithKey: CamelotKey? = nil,
                limit: Int = 100) {
        self.text = text
        self.positiveTerms = positiveTerms
        self.negativeTerms = negativeTerms
        self.bpmLo = bpmRange?.lowerBound
        self.bpmHi = bpmRange?.upperBound
        self.compatibleWithKey = compatibleWithKey
        self.limit = limit
    }

    public var bpmRange: ClosedRange<Double>? {
        get {
            guard let lo = bpmLo, let hi = bpmHi, lo <= hi else { return nil }
            return lo...hi
        }
        set {
            bpmLo = newValue?.lowerBound
            bpmHi = newValue?.upperBound
        }
    }

    public var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !positiveTerms.isEmpty
            || !negativeTerms.isEmpty
    }
}

/// One ranked hit: the track, the cosine similarity, the fused hybrid score,
/// and the per-component breakdown for the UI's "why it matched" (§10.5,
/// mockup `ipad/04b`).
public struct SearchResult: Sendable, Equatable {
    public let track: DJTrackRow
    /// Cosine similarity of the pooled vector to the query, 0...1.
    public let similarity: Double
    /// The hybrid score used for ordering (G.5 fused score).
    public let finalScore: Double
    public let reasons: RankBreakdown

    public init(track: DJTrackRow, similarity: Double, finalScore: Double,
                reasons: RankBreakdown) {
        self.track = track
        self.similarity = similarity
        self.finalScore = finalScore
        self.reasons = reasons
    }
}

/// A search's honest state (FR-SEM-6/8): results, coverage, latency, and —
/// when something is absent — a stated reason rather than a plausible-looking
/// empty list. Absence is a value, never a lie.
public struct SearchResponse: Sendable, Equatable {
    public let state: SearchState
    public let results: [SearchResult]
    /// Indexed ÷ total tracks, 0...1 (FR-SEM-8).
    public let coverage: Double
    public let latencyMillis: Double

    public init(state: SearchState, results: [SearchResult], coverage: Double,
                latencyMillis: Double) {
        self.state = state
        self.results = results
        self.coverage = coverage
        self.latencyMillis = latencyMillis
    }
}

public enum SearchState: Sendable, Equatable {
    /// Results are real for whatever is currently indexed.
    case ready
    /// FR-SEM-6: the text encoder is not downloaded — never a fake "no results".
    case textModelUnavailable
    /// The query was empty (no text and no refine terms).
    case emptyQuery
    /// Audio-to-audio: the reference track has no stored embedding yet.
    case unindexedReference
}

/// The hybrid search façade (§27.5, §16.5): text query, audio-to-audio
/// "more like this" (FR-SEM-7) with self-exclusion, +/− refinement (FR-SEM-4),
/// honest coverage (FR-SEM-8), and an index-change hook (§27.6). It wraps the
/// same pure scoring functions Tier B's SQL would wrap, so the tiers share one
/// ranking (AT-SEARCH-5).
public actor SemanticSearchService {

    public let pool: DatabasePool
    private let store: any VectorStore
    private let embedder: CLAPEmbedder
    private let resource: ModelResourceService
    private let weights: RankWeights
    private let bpmTolerance: Double
    private let poolSize: Int

    /// Coverage cache, warmed by `indexDidChange` (§27.6, FR-SEM-8).
    private var cachedCoverage: (indexed: Int, total: Int)?

    public init(pool: DatabasePool,
                store: any VectorStore,
                embedder: CLAPEmbedder,
                resource: ModelResourceService,
                weights: RankWeights = .default,
                bpmTolerance: Double = 3,
                poolSize: Int = 400) {
        self.pool = pool
        self.store = store
        self.embedder = embedder
        self.resource = resource
        self.weights = weights
        self.bpmTolerance = bpmTolerance
        self.poolSize = poolSize
    }

    // MARK: - Text search (FR-SEM-1/2/4)

    /// Text → embed (with +/− refine terms renormalizing the query vector,
    /// FR-SEM-4) → Tier A top-pool → Swift hybrid re-rank (§16.5, G.5).
    public func search(_ query: VibeQuery) async throws -> SearchResponse {
        let start = DispatchTime.now()
        let coverage = await coverageFraction()

        guard query.hasContent else {
            return SearchResponse(state: .emptyQuery, results: [], coverage: coverage,
                                  latencyMillis: elapsed(from: start))
        }
        guard await resource.isAvailable(.clapText) else {
            return SearchResponse(state: .textModelUnavailable, results: [],
                                  coverage: coverage, latencyMillis: elapsed(from: start))
        }

        let qvec = try await refinedQueryVector(query)
        let pool = try store.search(query: qvec, topK: max(poolSize, query.limit),
                                    isCancelled: { false })
        let target = try await target(for: query, referenceTrackID: nil)
        let ranked = try await rank(pool, target: target,
                                    hardBPM: query.bpmRange,
                                    hardKey: query.compatibleWithKey)
        let results = try await materialize(Array(ranked.prefix(query.limit)))

        return SearchResponse(state: .ready, results: results, coverage: coverage,
                              latencyMillis: elapsed(from: start))
    }

    /// Audio-to-audio "more like this" (FR-SEM-7): use the reference track's
    /// stored pooled vector, exclude the reference itself, and rank by musical
    /// compatibility to it (§27.5 — no text encoder involved).
    public func similar(to trackID: Int64, limit: Int = 100) async throws -> SearchResponse {
        let start = DispatchTime.now()
        let coverage = await coverageFraction()

        guard let stored = try await pool.read({ db in
            try DJTrackEmbedding.filter(Column("trackID") == trackID).fetchOne(db)
        }) else {
            return SearchResponse(state: .unindexedReference, results: [],
                                  coverage: coverage, latencyMillis: elapsed(from: start))
        }
        let qvec = VectorQuantization.dequantize(stored.int8Vector, scale: Float(stored.scale))
        let pool = try store.search(query: qvec, topK: max(poolSize, limit),
                                    isCancelled: { false })
            .filter { $0.rowID != trackID }
        let target = try await target(for: nil, referenceTrackID: trackID)
        let ranked = try await rank(pool, target: target, hardBPM: nil, hardKey: nil)
        let results = try await materialize(Array(ranked.prefix(limit)))

        return SearchResponse(state: .ready, results: results, coverage: coverage,
                              latencyMillis: elapsed(from: start))
    }

    // MARK: - Coverage (FR-SEM-8)

    /// Indexed ÷ total tracks, honest even when the index is partial. Cached;
    /// `indexDidChange` keeps the cache warm (§27.6).
    public func coverageFraction() async -> Double {
        let counts = await coverageCounts()
        return counts.total > 0 ? Double(counts.indexed) / Double(counts.total) : 0
    }

    public func coverageCounts() async -> (indexed: Int, total: Int) {
        if let cached = cachedCoverage { return cached }
        let counts = (try? await pool.read { db in
            let total = try DJTrack.fetchCount(db)
            let indexed = try DJTrackEmbedding
                .filter(Column("matrixRow") != nil).fetchCount(db)
            return (indexed, total)
        }) ?? (0, 0)
        cachedCoverage = counts
        return counts
    }

    /// Notified by the embedding coordinator when tracks are embedded (§27.6);
    /// refreshes the coverage cache so the next query reports honest numbers.
    public func indexDidChange(trackIDs: [Int64]) async {
        _ = trackIDs
        cachedCoverage = (try? await pool.read { db in
            let total = try DJTrack.fetchCount(db)
            let indexed = try DJTrackEmbedding
                .filter(Column("matrixRow") != nil).fetchCount(db)
            return (indexed, total)
        }) ?? cachedCoverage
    }

    // MARK: - Query vector

    /// Base text embedding plus +/− term vectors, renormalized after each
    /// adjustment (App. G.5: "added/subtracted and renormalized").
    private func refinedQueryVector(_ query: VibeQuery) async throws -> [Float] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var vec = [Float](repeating: 0, count: embedder.spec.dimensions)
        if !text.isEmpty {
            vec = try await embedder.embedText(text)
        }
        for term in query.positiveTerms {
            let termVec = try await embedder.embedText(term)
            vec = SemanticPooling.l2Normalized(zip(vec, termVec).map(+))
        }
        for term in query.negativeTerms {
            let termVec = try await embedder.embedText(term)
            vec = SemanticPooling.l2Normalized(zip(vec, termVec).map { $0 - $1 })
        }
        return vec
    }

    // MARK: - Scoring

    /// The `RankTarget` for a query: a text query constrains BPM (midpoint of
    /// the range) and/or Camelot; audio-to-audio targets the reference track's
    /// own musical attributes so "like this" means musically too.
    private func target(for query: VibeQuery?, referenceTrackID: Int64?) async throws
        -> RankTarget {
        if let referenceTrackID {
            let row = try await pool.read { db in
                try DJTrack.filter(Column("id") == referenceTrackID).fetchOne(db)
            }
            let phrase = try await phraseLength(for: referenceTrackID)
            return RankTarget(bpm: row?.bpm,
                              camelot: row?.camelot.flatMap(CamelotKey.init(code:)),
                              energy: row?.energy,
                              phraseLength: phrase,
                              bpmTolerance: bpmTolerance)
        }
        return RankTarget(bpm: query?.bpmRange.map { ($0.lowerBound + $0.upperBound) / 2 },
                          camelot: query?.compatibleWithKey,
                          bpmTolerance: bpmTolerance)
    }

    /// Hybrid re-rank over the scan's top pool (G.5), applying BPM/Camelot as
    /// hard filters first (they gate the candidate set) and as soft fit terms
    /// within it.
    private func rank(_ matches: [VectorMatch], target: RankTarget,
                      hardBPM: ClosedRange<Double>?, hardKey: CamelotKey?) async throws
        -> [RankedMatch] {
        let ids = matches.map(\.rowID)
        let rows = try await pool.read { db in
            try DJTrack.filter(ids.contains(Column("id"))).fetchAll(db)
        }
        let phrases = try await phraseLengths(for: ids)
        var rowsByID: [Int64: DJTrack] = [:]
        for row in rows { if let id = row.id { rowsByID[id] = row } }

        var scored: [RankedMatch] = []
        for match in matches {
            guard let row = rowsByID[match.rowID] else { continue }
            if let hardBPM {
                guard let bpm = row.bpm, hardBPM.contains(bpm) else { continue }
            }
            let camelot = row.camelot.flatMap(CamelotKey.init(code:))
            if let hardKey {
                guard let camelot, Camelot.compatible(hardKey).contains(camelot) else { continue }
            }
            let candidate = RankCandidate(semantic: Double(match.similarity),
                                          bpm: row.bpm,
                                          camelot: camelot,
                                          energy: row.energy,
                                          phraseLength: phrases[match.rowID])
            scored.append(RankedMatch(rowID: match.rowID,
                                      semantic: Double(match.similarity),
                                      breakdown: HybridRanker.fusedScore(candidate, target: target,
                                                                          weights: weights)))
        }
        return HybridRankerOrdering.order(scored)
    }

    /// Join ranked matches back to their `DJTrackRow` listings, preserving rank.
    private func materialize(_ ranked: [RankedMatch]) async throws -> [SearchResult] {
        guard !ranked.isEmpty else { return [] }
        let ids = ranked.map(\.rowID)
        let listings = try DJTrackRepository(pool: pool).tracks(ids: ids)
        var byID: [Int64: DJTrackRow] = [:]
        for listing in listings { byID[listing.id] = listing }

        return ranked.compactMap { match in
            guard let listing = byID[match.rowID] else { return nil }
            return SearchResult(track: listing,
                                similarity: match.semantic,
                                finalScore: match.breakdown.fused,
                                reasons: match.breakdown)
        }
    }

    // MARK: - Phrase data

    private func phraseLengths(for trackIDs: [Int64]) async throws -> [Int64: Double] {
        guard !trackIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: trackIDs.count).joined(separator: ",")
        return try await pool.read { db in
            var result: [Int64: Double] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT trackID, AVG(lengthBeats) AS phraseLen
                FROM phrase WHERE trackID IN (\(placeholders)) GROUP BY trackID
                """, arguments: StatementArguments(trackIDs))
            for row in rows {
                let trackID: Int64 = row["trackID"]
                let len: Double? = row["phraseLen"]
                if let len { result[trackID] = len }
            }
            return result
        }
    }

    private func phraseLength(for trackID: Int64) async throws -> Double? {
        (try await phraseLengths(for: [trackID]))[trackID]
    }

    private func elapsed(from start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}
