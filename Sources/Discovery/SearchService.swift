#if !os(watchOS)
import Foundation
import GRDB
import ParsoAudioAnalysis
import ParsoAudioNeural
import TonearmCore

public enum DiscoverySearchMode: Sendable, Equatable {
    /// Free text / refinements, ranked by CLAP similarity fused with musical
    /// attributes.
    case semantic
    /// "More like this track" — the reference's stored embedding, reference
    /// excluded, no text model.
    case similar(referenceTrackID: Int64)
    /// Hard SQL scope + BPM/key, stable metadata order, no semantic score.
    case filterOnly
    /// Empty text and no filters — an ordinary scoped library browse.
    case metadataBrowse
}

public struct DiscoverySearchResult: Sendable, Equatable {
    public let track: TrackRow
    /// Raw signed cosine (−1…1), exposed only as "similarity" — never a
    /// probability (plan §9). `nil` for filter-only / browse.
    public let similarity: Double?
    /// Fused hybrid score used for ordering. `nil` for filter-only / browse
    /// (no fabricated score).
    public let finalScore: Double?
    public let breakdown: RankBreakdown?

    public var trackID: Int64 { track.id }
}

public struct DiscoverySearchResponse: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case ready
        case validationFailed([QueryValidationIssue])
        case emptyLibrary
        case emptyScope
        case sourceUnavailable
        case zeroIndexed
        case indexingInProgress
        case modelMissing
        case modelDownloadFailed
        /// Similar-track query whose reference has no / a stale embedding —
        /// UI offers "Analyze this track" (plan §9).
        case unindexedReference
        /// Matching was requested but the anchor has no usable BPM/key
        /// analysis, so applying the requested gate would be dishonest.
        case matchingReferenceUnavailable
        case noMatches
        case cancelled
        /// A real SQL / vector-cache error occurred — distinct from a truthful
        /// `(0, 0)` coverage (plan §9: "SQL errors are errors, not `(0,0)`
        /// coverage"). The UI shows a retryable failure, not "no matches".
        case searchFailed
    }

    public let mode: DiscoverySearchMode
    public let state: State
    public let results: [DiscoverySearchResult]
    public let coverage: SearchRepository.Coverage?
    /// The vector-index generation the scan ran against (plan §8/§9). `nil`
    /// for filter-only / browse (no vector scan).
    public let indexGeneration: Int64?
    public let latencyMillis: Double
}

/// Unified-catalog retrieval (plan §9). One engine, one scoring path
/// (`HybridRanker`), shared by text search, similar-track search, saved
/// searches and auto-playlist candidate retrieval.
public actor SearchService {
    public static let defaultBPMTolerance: Double = 3

    private let writer: any DatabaseWriter
    private let repo: SearchRepository
    private let index: VectorIndex
    private let models: ModelManager
    private let weights: RankWeights
    private let bpmTolerance: Double
    private let executionContext: @Sendable () -> ModelManager.ExecutionContext

    private var jobPipelineVersion: Int { DiscoveryPipelineVersion.pipeline }
    private var analysisVersion: Int { DiscoveryPipelineVersion.musicalAnalysis }

    /// Test-only seam (plan §11 C06: "source / track deletion mid-query"):
    /// invoked once per 256-vector scan block, after the cancellation check,
    /// so a test can mutate the catalog (delete a track/source) while a single
    /// scan is genuinely in flight and assert the result set stays consistent.
    /// Never set in production.
    private var scanBlockHook: (@Sendable () async -> Void)?

    public func setScanBlockHookForTesting(_ hook: @escaping @Sendable () async -> Void) {
        scanBlockHook = hook
    }

    public init(
        writer: any DatabaseWriter,
        index: VectorIndex,
        models: ModelManager,
        weights: RankWeights = .default,
        bpmTolerance: Double = SearchService.defaultBPMTolerance,
        executionContext: @escaping @Sendable () -> ModelManager.ExecutionContext = { .foreground }
    ) {
        self.writer = writer
        self.repo = SearchRepository(reader: writer)
        self.index = index
        self.models = models
        self.weights = weights
        self.bpmTolerance = bpmTolerance
        self.executionContext = executionContext
    }

    // MARK: - Entry points

    /// Run a text/filter query. `referenceTrackID` switches to similar-track
    /// mode (text is then ignored). `isCancelled` is polled through text
    /// inference and every scan block (plan §9); a cancelled search returns
    /// `.cancelled` and updates nothing.
    public func search(
        _ raw: DiscoverySearchQuery,
        referenceTrackID: Int64? = nil,
        matchingReferenceTrackID: Int64? = nil,
        matchingTracksOnly: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> DiscoverySearchResponse {
        let start = DispatchTime.now()

        let validated: ValidatedQuery
        switch ValidatedQuery.validate(raw) {
        case .success(let v): validated = v
        case .failure(let failure):
            return response(
                mode: .semantic, state: .validationFailed(failure.issues), results: [], coverage: nil,
                generation: nil, start: start)
        }

        let coverage: SearchRepository.Coverage
        do {
            coverage = try repo.coverage(for: validated, pipelineVersion: jobPipelineVersion)
        } catch {
            // A real SQL error is an error, not (0,0) coverage (plan §9).
            return response(
                mode: .semantic, state: .searchFailed, results: [], coverage: nil,
                generation: nil, start: start)
        }

        switch coverage.state {
        case .emptyLibrary:
            return response(mode: modeFor(validated, referenceTrackID), state: .emptyLibrary,
                results: [], coverage: coverage, generation: nil, start: start)
        case .emptyScope:
            return response(mode: modeFor(validated, referenceTrackID), state: .emptyScope,
                results: [], coverage: coverage, generation: nil, start: start)
        case .sourceUnavailable:
            return response(mode: modeFor(validated, referenceTrackID), state: .sourceUnavailable,
                results: [], coverage: coverage, generation: nil, start: start)
        default:
            break
        }

        if isCancelled() { return cancelledResponse(modeFor(validated, referenceTrackID), start) }

        if let referenceTrackID {
            return await runSimilar(
                validated, referenceTrackID: referenceTrackID, coverage: coverage,
                matchingTracksOnly: matchingTracksOnly,
                isCancelled: isCancelled, start: start)
        }
        if !validated.hasText {
            return await runFilterOnlyOrBrowse(
                validated, coverage: coverage, isCancelled: isCancelled, start: start)
        }
        return await runSemantic(
            validated, coverage: coverage,
            matchingReferenceTrackID: matchingReferenceTrackID,
            matchingTracksOnly: matchingTracksOnly,
            isCancelled: isCancelled, start: start)
    }

    /// Shared candidate retrieval for saved searches and auto-playlist
    /// generation (plan §9): the same scope/filter/scoring path, returning
    /// ranked core track IDs (never a duplicate scoring implementation).
    public func candidateTrackIDs(
        _ raw: DiscoverySearchQuery,
        referenceTrackID: Int64? = nil
    ) async -> [Int64] {
        let response = await search(raw, referenceTrackID: referenceTrackID)
        return response.results.map(\.trackID)
    }

    /// Metadata-search companion for the matching toggle. It applies the same
    /// hard musical gate without requiring a vector or text model.
    public func matchingTrackIDs(
        _ raw: DiscoverySearchQuery, referenceTrackID: Int64
    ) async -> [Int64] {
        guard case .success(let query) = ValidatedQuery.validate(raw),
              let attrs = try? repo.referenceAttributes(
                trackID: referenceTrackID, pipelineVersion: analysisVersion),
              let bpm = attrs.bpm, let camelot = attrs.camelot else { return [] }
        let target = MusicalMatchReference(bpm: bpm, camelot: camelot)
        return Array((try? repo.eligibleTrackIDs(for: query, musicalMatch: target)) ?? [])
    }

    // MARK: - Modes

    private func modeFor(_ q: ValidatedQuery, _ ref: Int64?) -> DiscoverySearchMode {
        if let ref { return .similar(referenceTrackID: ref) }
        if !q.hasText { return q.hasHardMusicalFilter ? .filterOnly : .metadataBrowse }
        return .semantic
    }

    private func runFilterOnlyOrBrowse(
        _ q: ValidatedQuery, coverage: SearchRepository.Coverage,
        isCancelled: @Sendable () -> Bool, start: DispatchTime
    ) async -> DiscoverySearchResponse {
        let mode: DiscoverySearchMode = q.hasHardMusicalFilter ? .filterOnly : .metadataBrowse
        do {
            let rows = try repo.orderedScopeRows(
                for: q, applyHardFilters: q.hasHardMusicalFilter, limit: q.limit)
            if isCancelled() { return cancelledResponse(mode, start) }
            let results = rows.map {
                DiscoverySearchResult(track: $0, similarity: nil, finalScore: nil, breakdown: nil)
            }
            return response(
                mode: mode, state: results.isEmpty ? .noMatches : .ready, results: results,
                coverage: coverage, generation: nil, start: start)
        } catch {
            return response(
                mode: mode, state: .searchFailed, results: [], coverage: coverage,
                generation: nil, start: start)
        }
    }

    private func runSemantic(
        _ q: ValidatedQuery, coverage: SearchRepository.Coverage,
        matchingReferenceTrackID: Int64?, matchingTracksOnly: Bool,
        isCancelled: @escaping @Sendable () -> Bool, start: DispatchTime
    ) async -> DiscoverySearchResponse {
        let encoder: any SemanticModel
        do {
            encoder = try await models.textEncoder(context: executionContext())
        } catch ModelManager.ModelManagerError.resourcesUnavailable {
            return response(mode: .semantic, state: .modelMissing, results: [], coverage: coverage,
                generation: nil, start: start)
        } catch {
            return response(mode: .semantic, state: .modelDownloadFailed, results: [],
                coverage: coverage, generation: nil, start: start)
        }

        if isCancelled() { return cancelledResponse(.semantic, start) }

        let queryVector: [Float]
        do {
            queryVector = try await refinedQueryVector(q, encoder: encoder)
        } catch {
            return response(mode: .semantic, state: .modelDownloadFailed, results: [],
                coverage: coverage, generation: nil, start: start)
        }
        if isCancelled() { return cancelledResponse(.semantic, start) }

        // Plain prose has no musical target — energy/phrase are never invented
        // from text (plan §9). A BPM range / key the user set as a filter is
        // BOTH a hard gate (applied in `eligibleTrackIDs`) AND a soft fit
        // target within the gated set, so the hybrid re-rank still orders by
        // closeness to the range midpoint / key.
        let target = RankTarget(
            bpm: q.bpmRange.map { ($0.lowerBound + $0.upperBound) / 2 },
            camelot: q.compatibleKey,
            energy: nil, phraseLength: nil, bpmTolerance: bpmTolerance)

        let musicalMatch: MusicalMatchReference?
        if matchingTracksOnly {
            guard let matchingReferenceTrackID,
                  let attrs = try? repo.referenceAttributes(
                    trackID: matchingReferenceTrackID, pipelineVersion: analysisVersion),
                  let bpm = attrs.bpm, let camelot = attrs.camelot else {
                return response(mode: .semantic, state: .matchingReferenceUnavailable, results: [],
                    coverage: coverage, generation: nil, start: start)
            }
            musicalMatch = MusicalMatchReference(bpm: bpm, camelot: camelot)
        } else {
            musicalMatch = nil
        }

        return await scanAndRank(
            mode: .semantic, query: q, queryVector: queryVector, target: target,
            musicalMatch: musicalMatch, excludeTrackID: nil,
            includeUnknownMusical: !q.hasHardMusicalFilter,
            coverage: coverage, isCancelled: isCancelled, start: start)
    }

    private func runSimilar(
        _ q: ValidatedQuery, referenceTrackID: Int64, coverage: SearchRepository.Coverage,
        matchingTracksOnly: Bool,
        isCancelled: @escaping @Sendable () -> Bool, start: DispatchTime
    ) async -> DiscoverySearchResponse {
        let mode = DiscoverySearchMode.similar(referenceTrackID: referenceTrackID)

        let referenceRow: DiscoveryEmbedding?
        do {
            referenceRow = try await writer.read { db in
                try DiscoveryEmbedding.fetchOne(db, key: referenceTrackID)
            }
        } catch {
            return response(mode: mode, state: .searchFailed, results: [], coverage: coverage,
                generation: nil, start: start)
        }
        guard let referenceRow,
            referenceRow.modelVersion == DiscoveryPipelineVersion.model,
            referenceRow.preprocessingVersion == DiscoveryPipelineVersion.preprocessing,
            referenceRow.samplingVersion == DiscoveryPipelineVersion.sampling
        else {
            return response(mode: mode, state: .unindexedReference, results: [], coverage: coverage,
                generation: nil, start: start)
        }

        let int8 = [Int8](unsafeUninitializedCapacity: referenceRow.quantizedVector.count) {
            buf, count in
            referenceRow.quantizedVector.copyBytes(
                to: UnsafeMutableRawBufferPointer(buf), count: referenceRow.quantizedVector.count)
            count = referenceRow.quantizedVector.count
        }
        let queryVector = VectorQuantization.dequantize(int8, scale: Float(referenceRow.scale))

        let refAttrs = (try? repo.referenceAttributes(
            trackID: referenceTrackID, pipelineVersion: analysisVersion)) ?? nil
        let musicalMatch: MusicalMatchReference?
        if matchingTracksOnly {
            guard let refAttrs, let bpm = refAttrs.bpm, let camelot = refAttrs.camelot else {
                return response(mode: mode, state: .matchingReferenceUnavailable, results: [],
                    coverage: coverage, generation: nil, start: start)
            }
            musicalMatch = MusicalMatchReference(bpm: bpm, camelot: camelot)
        } else {
            musicalMatch = nil
        }
        let target = RankTarget(
            bpm: refAttrs?.bpm, camelot: refAttrs?.camelot, energy: refAttrs?.energy,
            phraseLength: refAttrs?.phraseLength, bpmTolerance: bpmTolerance)

        return await scanAndRank(
            mode: mode, query: q, queryVector: queryVector, target: target,
            musicalMatch: musicalMatch,
            excludeTrackID: referenceTrackID, includeUnknownMusical: !q.hasHardMusicalFilter,
            coverage: coverage, isCancelled: isCancelled, start: start)
    }

    // MARK: - Exact chunked hybrid scan (plan §9)

    private func scanAndRank(
        mode: DiscoverySearchMode, query q: ValidatedQuery, queryVector: [Float],
        target: RankTarget, musicalMatch: MusicalMatchReference?,
        excludeTrackID: Int64?, includeUnknownMusical: Bool,
        coverage: SearchRepository.Coverage,
        isCancelled: @escaping @Sendable () -> Bool, start: DispatchTime,
        attempt: Int = 0
    ) async -> DiscoverySearchResponse {

        let snapshot: VectorIndex.Snapshot
        do {
            snapshot = try await index.currentSnapshot()
        } catch {
            return response(mode: mode, state: .searchFailed, results: [], coverage: coverage,
                generation: nil, start: start)
        }
        guard snapshot.rowCount > 0, snapshot.dimensions == queryVector.count else {
            return response(
                mode: mode, state: coverage.indexed == 0 ? .zeroIndexed : .noMatches,
                results: [], coverage: coverage, generation: snapshot.generation, start: start)
        }

        // Eligibility: scope ∩ hard BPM/key, BEFORE top-K truncation (plan §9).
        let eligible: Set<Int64>
        do {
            eligible = try repo.eligibleTrackIDs(for: q, musicalMatch: musicalMatch)
        } catch {
            return response(mode: mode, state: .searchFailed, results: [], coverage: coverage,
                generation: snapshot.generation, start: start)
        }
        let attributes = (try? repo.attributes(pipelineVersion: analysisVersion)) ?? [:]

        // Exact scan over ALL eligible vectors, hybrid-scored during the scan
        // so no fixed semantic shortlist can hide a better hybrid result.
        var topK = BoundedTopK(capacity: q.limit)
        let rowCount = snapshot.rowCount
        var row = 0
        while row < rowCount {
            if isCancelled() { return cancelledResponse(mode, start) }
            if let scanBlockHook { await scanBlockHook() }
            let blockEnd = min(row + 256, rowCount)
            while row < blockEnd {
                defer { row += 1 }
                let trackID = snapshot.trackIDByRow[row]
                if trackID == excludeTrackID { continue }
                if !eligible.contains(trackID) { continue }

                let vec = snapshot.dequantizedRow(row)
                var dot: Float = 0
                for i in 0..<vec.count { dot += vec[i] * queryVector[i] }
                let similarity = Double(dot)

                let attr = attributes[trackID]
                let candidate = RankCandidate(
                    semantic: similarity,
                    bpm: attr?.bpm, camelot: attr?.camelot, energy: attr?.energy,
                    phraseLength: attr?.phraseLength)
                let breakdown = HybridRanker.fusedScore(
                    candidate, target: target, weights: weights)
                topK.insert(
                    Scored(
                        trackID: trackID, similarity: similarity, finalScore: breakdown.fused,
                        breakdown: breakdown))
            }
        }

        _ = includeUnknownMusical  // documented: no-filter path already includes
        // tracks missing BPM/key because eligibility did not join analysis.

        let ordered = topK.sorted()
        if ordered.isEmpty {
            return response(mode: mode, state: .noMatches, results: [], coverage: coverage,
                generation: snapshot.generation, start: start)
        }

        let rows: [TrackRow]
        do {
            rows = try repo.materialize(ordered.map(\.trackID))
        } catch {
            return response(mode: mode, state: .noMatches, results: [], coverage: coverage,
                generation: snapshot.generation, start: start)
        }
        var rowByID: [Int64: TrackRow] = [:]
        for r in rows { rowByID[r.id] = r }

        // Live-ID revalidation (plan §8/§9): a track/source deleted *during*
        // this scan is still in the in-memory snapshot but no longer
        // materializes. If that materially changed the result, retry once
        // against a fresh snapshot before returning; otherwise return the
        // consistent (deleted-ID-free) set we have.
        let missing = ordered.contains { rowByID[$0.trackID] == nil }
        if missing, attempt == 0 {
            // `currentSnapshot()` on the retry re-checks the live signature and
            // rebuilds from the (now cascade-trimmed) embedding rows.
            return await scanAndRank(
                mode: mode, query: q, queryVector: queryVector, target: target,
                musicalMatch: musicalMatch,
                excludeTrackID: excludeTrackID, includeUnknownMusical: includeUnknownMusical,
                coverage: coverage, isCancelled: isCancelled, start: start, attempt: 1)
        }

        let results: [DiscoverySearchResult] = ordered.compactMap { scored in
            guard let track = rowByID[scored.trackID] else { return nil }
            return DiscoverySearchResult(
                track: track, similarity: scored.similarity, finalScore: scored.finalScore,
                breakdown: scored.breakdown)
        }
        if isCancelled() { return cancelledResponse(mode, start) }
        return response(
            mode: mode, state: results.isEmpty ? .noMatches : .ready, results: results,
            coverage: coverage, generation: snapshot.generation, start: start)
    }

    // MARK: - Query vector

    /// Base text embedding plus +/- refinement term vectors, renormalized
    /// after each adjustment — soft nudges, not guarantees (plan §9).
    private func refinedQueryVector(
        _ q: ValidatedQuery, encoder: any SemanticModel
    ) async throws -> [Float] {
        var vec = [Float](repeating: 0, count: encoder.spec.dimensions)
        if !q.text.isEmpty {
            vec = try await encoder.embedText(q.text)
        }
        for term in q.positiveRefinements {
            let t = try await encoder.embedText(term)
            vec = SemanticPooling.l2Normalized(zip(vec, t).map(+))
        }
        for term in q.negativeRefinements {
            let t = try await encoder.embedText(term)
            vec = SemanticPooling.l2Normalized(zip(vec, t).map(-))
        }
        return SemanticPooling.l2Normalized(vec)
    }

    // MARK: - Helpers

    private func cancelledResponse(
        _ mode: DiscoverySearchMode, _ start: DispatchTime
    ) -> DiscoverySearchResponse {
        response(mode: mode, state: .cancelled, results: [], coverage: nil, generation: nil,
            start: start)
    }

    private func response(
        mode: DiscoverySearchMode, state: DiscoverySearchResponse.State,
        results: [DiscoverySearchResult], coverage: SearchRepository.Coverage?,
        generation: Int64?, start: DispatchTime
    ) -> DiscoverySearchResponse {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        return DiscoverySearchResponse(
            mode: mode, state: state, results: results, coverage: coverage,
            indexGeneration: generation, latencyMillis: ms)
    }
}

// MARK: - Bounded top-K with the pinned tie-break

private struct Scored: Sendable, Equatable {
    let trackID: Int64
    let similarity: Double
    let finalScore: Double
    let breakdown: RankBreakdown
}

/// Fixed-capacity top-K by the plan's exact tie-break (plan §9):
/// finalScore desc, then semantic similarity desc, then core track id asc.
/// Kept sorted on insert; capacity is <=200 so this is cheap and exact.
private struct BoundedTopK {
    private var items: [Scored] = []
    private let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    static func orderedBefore(_ a: Scored, _ b: Scored) -> Bool {
        if a.finalScore != b.finalScore { return a.finalScore > b.finalScore }
        if a.similarity != b.similarity { return a.similarity > b.similarity }
        return a.trackID < b.trackID
    }

    mutating func insert(_ candidate: Scored) {
        if items.count < capacity {
            let idx = items.firstIndex { !Self.orderedBefore($0, candidate) } ?? items.count
            items.insert(candidate, at: idx)
            return
        }
        guard let worst = items.last, Self.orderedBefore(candidate, worst) else { return }
        items.removeLast()
        let idx = items.firstIndex { !Self.orderedBefore($0, candidate) } ?? items.count
        items.insert(candidate, at: idx)
    }

    func sorted() -> [Scored] { items }
}
#endif
