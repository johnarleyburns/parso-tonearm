import Foundation
import GRDB
import TonearmCore
import TonearmDiscovery

/// Resolution (§28A.3 step 1, plan §2.7): turn a `PlaylistGenerationRequest`
/// into a resolved candidate pool via the unified `SearchService`/
/// `DiscoverySearchQuery` engine. Split out of `PlaylistGenerator.swift`;
/// `resolve(request:)` is called from `generate(_:)` there, so it stays
/// `internal` (not `private`) — everything else here is used only within
/// this file and stays `private`.
extension PlaylistGenerator {
    struct ResolvedCandidates {
        var candidates: [TrackFeatures]
        var semanticScores: [Int64: Double]
        var requestedCount: Int
        var isShortPool: Bool
        var slotZeroLock: Int64?
    }

    func resolve(request: PlaylistGenerationRequest) async throws -> ResolvedCandidates {
        let anchor = try await anchorQuery(for: request)

        let provisionalCount = request.targetTrackCount ?? PlaylistSequencer.maxTrackCount
        let desired = min(PlaylistSequencer.generatorPoolCap, max(8 * max(provisionalCount, 1), 1))
        var query = anchor.query
        query.limit = min(desired, ValidatedQuery.maxLimit)

        let response = await searchService.search(query, referenceTrackID: anchor.referenceTrackID,
                                                   isCancelled: { Task.isCancelled })
        let semanticScores = Dictionary(uniqueKeysWithValues:
            response.results.compactMap { result -> (Int64, Double)? in
                guard let similarity = result.similarity else { return nil }
                return (result.trackID, similarity)
            })

        var candidates = try await loadCandidates(
            ids: response.results.map(\.trackID), constraints: request.constraints)

        let rejections = try await loadRejections()
        candidates.removeAll { rejections.contains($0.trackID) }

        let requestedCount = estimatedCount(request: request, candidates: candidates)

        // Audio-seeded briefs pin their opening: the seed track joins the pool
        // (it may be outside the retrieved pool, or excluded as its own
        // reference by `.similar` mode) and is locked at slot 0.
        if let seedID = anchor.slotZeroLock, let seed = try await loadSeedFeatures(seedID) {
            candidates.append(seed)
        }

        let isShortPool = candidates.count < requestedCount
        return ResolvedCandidates(candidates: candidates,
                                  semanticScores: semanticScores,
                                  requestedCount: requestedCount,
                                  isShortPool: isShortPool,
                                  slotZeroLock: anchor.slotZeroLock)
    }

    private struct AnchorQuery {
        var query: DiscoverySearchQuery
        var referenceTrackID: Int64?
        var slotZeroLock: Int64?
    }

    /// The semantic anchor: a seed track's own stored embedding (`.similar`
    /// mode — skips the text encoder entirely), else a crate's stored query,
    /// else the prompt/chip text, else (fixing "filter-only rejected") a
    /// BPM-range-only brief with no text at all, which is still a valid
    /// `.filterOnly` anchor under the unified contract.
    private func anchorQuery(for request: PlaylistGenerationRequest) async throws -> AnchorQuery {
        if let seedID = request.seedTrackID, try await hasEmbedding(trackID: seedID) {
            return AnchorQuery(query: baseQuery(for: request), referenceTrackID: seedID,
                               slotZeroLock: seedID)
        }
        if let crateID = request.seedCrateID, let crateAnchor = try await crateQuery(id: crateID),
           hasContent(crateAnchor) {
            var query = baseQuery(for: request)
            query.text = crateAnchor.text
            query.positiveRefinements = crateAnchor.positiveRefinements + request.positiveTerms
            query.negativeRefinements = crateAnchor.negativeRefinements + request.negativeTerms
            return AnchorQuery(query: query, referenceTrackID: nil, slotZeroLock: nil)
        }
        let promptQuery = baseQuery(for: request)
        if hasContent(promptQuery) || promptQuery.bpmMin != nil || promptQuery.bpmMax != nil {
            return AnchorQuery(query: promptQuery, referenceTrackID: nil, slotZeroLock: nil)
        }
        throw PlaylistGeneratorError.noAnchor
    }

    /// The request's own prompt/chips/BPM/scope as a `DiscoverySearchQuery` —
    /// the common starting point every anchor path refines.
    private func baseQuery(for request: PlaylistGenerationRequest) -> DiscoverySearchQuery {
        DiscoverySearchQuery(text: request.prompt,
                             positiveRefinements: request.positiveTerms,
                             negativeRefinements: request.negativeTerms,
                             sourceIDs: request.sourceIDs,
                             bpmMin: request.constraints.bpmRange?.lowerBound,
                             bpmMax: request.constraints.bpmRange?.upperBound,
                             limit: ValidatedQuery.defaultLimit)
    }

    private func hasContent(_ query: DiscoverySearchQuery) -> Bool {
        !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !query.positiveRefinements.isEmpty
            || !query.negativeRefinements.isEmpty
    }

    /// `smart_crate.queryJSON` stores a `DiscoverySearchQuery` (`SmartCrateRepository`
    /// is the writer) — decoded and consumed natively here now, no adapter.
    private func crateQuery(id: Int64) async throws -> DiscoverySearchQuery? {
        try await pool.read { db in
            guard let crate = try SmartCrate.fetchOne(db, key: id) else { return nil }
            return try DiscoverySearchQuery.decodeJSON(crate.queryJSON)
        }
    }

    private func hasEmbedding(trackID: Int64) async throws -> Bool {
        try await library.dbQueue.read { db in
            try DiscoveryEmbedding.filter(Column("trackId") == trackID).fetchCount(db) > 0
        }
    }

    private func loadRejections() async throws -> Set<Int64> {
        guard let briefID = lastBriefID else { return [] }
        return Set(try repository.rejections(for: briefID))
    }

    /// n for the brief (§28A.3 step 2): the requested count, else round the
    /// duration target against the pool's median duration.
    private func estimatedCount(request: PlaylistGenerationRequest,
                                candidates: [TrackFeatures]) -> Int {
        if let n = request.targetTrackCount, n > 0 { return n }
        if let target = request.targetSeconds, target > 0 {
            let median = medianDuration(candidates)
            if median > 0 {
                return min(max(1, Int((target / median).rounded())),
                           PlaylistSequencer.maxTrackCount)
            }
        }
        return PlaylistSequencer.maxTrackCount
    }

    private func medianDuration(_ candidates: [TrackFeatures]) -> Double {
        guard !candidates.isEmpty else { return 0 }
        let sorted = candidates.map(\.durationSec).sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
