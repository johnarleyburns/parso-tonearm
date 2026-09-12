import Foundation
import GRDB
import ParsoAudioAnalysis
import TonearmCore
import TonearmDiscovery

/// The input to one generation (plan §2.7, §3.3): the semantic anchor, the arc,
/// the target length, the constraints, the seed, and any pinned slots. The UI
/// model builds one from the brief field and the editable chips (§28A.6); the
/// generator persists it as the `auto_playlist_brief` row.
public struct PlaylistGenerationRequest: Sendable, Equatable {
    /// The whole brief, embedded as the semantic anchor `q` (§27.5).
    public var prompt: String
    public var positiveTerms: [String]
    public var negativeTerms: [String]
    public var arc: EnergyArc
    /// XOR with `targetTrackCount` (FR-PLIST-2's T).
    public var targetSeconds: Double?
    public var targetTrackCount: Int?
    public var constraints: SequencingConstraints
    /// Audio-seeded: the seed track's pooled vector skips the text encoder
    /// (AT-PLIST-2's ≤ 400 ms path) and pins slot 0 (§41.6 "Start from").
    public var seedTrackID: Int64?
    /// "Start from a saved vibe": the crate's stored `DiscoverySearchQuery` becomes the anchor.
    public var seedCrateID: Int64?
    /// Explicit selected scope (C02 fix — the old DJ-local pipeline had no
    /// notion of scope at all). `nil` means the whole library, matching
    /// `DiscoverySearchQuery.sourceIDs`. Not yet exposed by any UI control —
    /// present so the capability exists on the shared contract, the same
    /// state `VibeSearchModel`'s `currentQuery` left it in this session.
    public var sourceIDs: [Int64]?
    /// Seeded tie-breaks (NFR-DET-1); a fresh seed is what varies "regenerate".
    public var randomSeed: UInt64
    /// slot → trackID for pinned slots (FR-PLIST-6).
    public var locks: [Int: Int64]

    public init(prompt: String,
                positiveTerms: [String] = [],
                negativeTerms: [String] = [],
                arc: EnergyArc,
                targetSeconds: Double? = nil,
                targetTrackCount: Int? = nil,
                constraints: SequencingConstraints = SequencingConstraints(),
                seedTrackID: Int64? = nil,
                seedCrateID: Int64? = nil,
                sourceIDs: [Int64]? = nil,
                randomSeed: UInt64,
                locks: [Int: Int64] = [:]) {
        self.prompt = prompt
        self.positiveTerms = positiveTerms
        self.negativeTerms = negativeTerms
        self.arc = arc
        self.targetSeconds = targetSeconds
        self.targetTrackCount = targetTrackCount
        self.constraints = constraints
        self.seedTrackID = seedTrackID
        self.seedCrateID = seedCrateID
        self.sourceIDs = sourceIDs
        self.randomSeed = randomSeed
        self.locks = locks
    }
}

/// The result of a generation: the persisted brief + result + items plus the
/// honest pool state (plan §2.7) — `isShortPool` is the "say so" when the
/// library cannot supply the requested length.
public struct PlaylistGeneration: Sendable, Equatable {
    public var brief: AutoPlaylistBrief
    public var result: AutoPlaylistResult
    public var items: [AutoPlaylistItem]
    /// The target count the brief asked for (from `targetTrackCount`, or derived
    /// from `targetSeconds` against the pool's median duration).
    public var requestedCount: Int
    public var candidateCount: Int
    /// True when the filtered pool was short of `requestedCount` — the sequence
    /// is still generated, honestly shorter (never padded with tracks that don't fit).
    public var isShortPool: Bool

    public init(brief: AutoPlaylistBrief,
                result: AutoPlaylistResult,
                items: [AutoPlaylistItem],
                requestedCount: Int,
                candidateCount: Int,
                isShortPool: Bool) {
        self.brief = brief
        self.result = result
        self.items = items
        self.requestedCount = requestedCount
        self.candidateCount = candidateCount
        self.isShortPool = isShortPool
    }
}

public enum PlaylistGeneratorError: Error, LocalizedError, Equatable {
    /// No text and no usable seed-track embedding to anchor the search on.
    case noAnchor
    /// Nothing survived the semantic pool + hard constraints + rejections.
    case noCandidates
    /// An interaction (reject/replace/extend/reshuffle) with nothing generated yet.
    case noGeneration
    case persistFailed

    public var errorDescription: String? {
        switch self {
        case .noAnchor: return "Nothing to search for — add a brief or start from a track."
        case .noCandidates: return "No tracks in your library fit this brief's constraints."
        case .noGeneration: return "Generate a playlist before editing it."
        case .persistFailed: return "Could not save the generated playlist."
        }
    }
}

/// The generation actor (plan §2.7, §3.3): resolve candidates → CDF ranks →
/// pure `sequence` → persist. `generate` is the whole pipeline; every interaction
/// (§28A.4) is a constrained re-run over the same resolved pool, so nothing is a
/// fresh roll of the dice.
///
/// C02 (IMPLEMENT_CLAP_PLAN.md, Slice B): candidate retrieval is rewired onto
/// the unified `SearchService`/`DiscoverySearchQuery` engine (the same one
/// `VibeSearchModel`/`SmartCrateRepository` use), tracking candidates by core
/// `track.id` throughout — never the deleted DJ-local `VectorStore`/`DJTrack`
/// path. This fixes the old pipeline's four real bugs for free:
/// - **top-400-before-filter**: the BPM hard filter now travels as
///   `DiscoverySearchQuery.bpmMin/bpmMax`, applied by `SearchService` to the
///   ELIGIBLE set before top-K truncation, not after a fixed-size vector scan.
/// - **filter-only rejected**: a BPM-only brief with no prompt/seed/crate text
///   now runs as `SearchService`'s own `.filterOnly` mode instead of throwing
///   `.noAnchor` — `hasHardMusicalFilter` counts as an anchor here.
/// - **no selected-source scope**: `PlaylistGenerationRequest.sourceIDs` now
///   exists and threads straight into `DiscoverySearchQuery.sourceIDs`.
/// - **cancellation always false**: `isCancelled: { Task.isCancelled }` is
///   threaded into `SearchService.search`, reflecting the ambient Swift
///   `Task`'s real cancellation instead of a hard-coded `{ false }`.
///
/// Two DIFFERENT databases stay in play here, same as `VibeSearchModel`: `pool`
/// (DJ-local — `auto_playlist_brief/result/item`, `smart_crate/crate_rule`,
/// still DJ-only operational data per the plan amendment) and `library` (the
/// ONE core catalog `SearchService` and the candidate-feature loaders read).
///
/// The old "widen the pool and re-scan" step is gone, not merely renamed: it
/// existed only to work around top-K preceding the hard filter. `SearchService`
/// already scans every ELIGIBLE vector exactly (no fixed shortlist), so a
/// single query at the desired pool size is sufficient. The one real, honest
/// regression from this: `ValidatedQuery.maxLimit` (200) is a lower ceiling
/// than the old widened cap (up to 2,400) for very large requested track
/// counts — a short pool is still reported honestly (`isShortPool`), never
/// silently padded, and this ceiling is a property of the ONE shared retrieval
/// contract every caller now gets, not a PlaylistGenerator-specific cut corner.
public actor PlaylistGenerator {
    /// DJ-local: `auto_playlist_brief/result/item` persistence, `smart_crate`
    /// lookups for `seedCrateID`. NOT the core catalog.
    public let pool: DatabasePool
    /// The ONE core music catalog (plan §3) — candidate features, embeddings,
    /// musical analysis.
    private let library: LibraryStore
    private let searchService: SearchService
    private let repository: AutoPlaylistRepository

    /// The last completed generation, for reject / replace / extend / reshuffle.
    private var lastRequest: PlaylistGenerationRequest?
    private var lastBriefID: Int64?
    private var lastCandidates: [TrackFeatures]?
    private var lastSlots: [SequencedSlot]?
    private var lastSemanticScores: [Int64: Double]?

    public init(pool: DatabasePool, library: LibraryStore, searchService: SearchService) {
        self.pool = pool
        self.library = library
        self.searchService = searchService
        self.repository = AutoPlaylistRepository(pool: pool)
    }

    // MARK: - Generate

    /// Full pipeline (§28A.3 step 1): resolve the anchor, run the unified
    /// retrieval engine, apply the constraints it doesn't cover natively,
    /// subtract this brief's rejections, map energies to CDF ranks, run the
    /// pure beam search, and persist brief + result + items.
    public func generate(_ request: PlaylistGenerationRequest) async throws -> PlaylistGeneration {
        let resolved = try await resolve(request: request)
        let candidates = resolved.candidates
        guard !candidates.isEmpty else { throw PlaylistGeneratorError.noCandidates }

        // Map the candidate set's own energy distribution onto [0,1] (§28A.5):
        // "1.0" always means the most energetic thing that fits this brief.
        let ranks = EmpiricalEnergyCDF.ranks(
            energies: candidates.map { (trackID: $0.trackID, energy: $0.energy) })
        var scored = candidates
        for index in scored.indices {
            scored[index].energy = ranks[scored[index].trackID] ?? PlaylistSequencer.neutral
        }

        var locks = request.locks
        if let seedLock = resolved.slotZeroLock, locks[0] == nil {
            locks[0] = seedLock
        }
        let brief = PlaylistBrief(targetSeconds: request.targetSeconds,
                                  targetTrackCount: request.targetTrackCount,
                                  arc: request.arc,
                                  constraints: request.constraints,
                                  locks: locks,
                                  semanticScores: resolved.semanticScores)
        let slots = PlaylistSequencer.sequence(candidates: scored, brief: brief,
                                               seed: request.randomSeed)
        guard !slots.isEmpty else { throw PlaylistGeneratorError.noCandidates }

        let result = makeResult(slots: slots, candidates: scored, request: request)
        let items = makeItems(slots: slots, locks: locks)
        let persisted = try await persist(request: request, result: result, items: items)

        lastRequest = request
        lastBriefID = persisted.brief.id
        lastCandidates = scored
        lastSlots = slots
        lastSemanticScores = resolved.semanticScores

        return PlaylistGeneration(brief: persisted.brief,
                                  result: persisted.result,
                                  items: persisted.items,
                                  requestedCount: resolved.requestedCount,
                                  candidateCount: scored.count,
                                  isShortPool: resolved.isShortPool)
    }

    // MARK: - Interactions (§28A.4)

    /// Reject a track: row it into `auto_playlist_rejection` against the brief,
    /// then re-run with the remaining locks intact — so the second generation is
    /// visibly better than the first (plan §2.7).
    public func reject(trackID: Int64) async throws -> PlaylistGeneration {
        guard let request = lastRequest, let briefID = lastBriefID else {
            throw PlaylistGeneratorError.noGeneration
        }
        try repository.upsertRejections(briefID: briefID, trackIDs: [trackID])
        return try await generate(request)
    }

    /// Replace one slot: swap in the best candidate that minimises
    /// `transitionCost(prev, x) + transitionCost(x, next) + arcError(x)`,
    /// holding neighbours fixed and re-validating spacing (§28A.4). Sub-ms.
    public func replaceSlot(slot: Int) async throws -> PlaylistGeneration {
        guard let request = lastRequest, let candidates = lastCandidates,
              let slots = lastSlots, let semanticScores = lastSemanticScores else {
            throw PlaylistGeneratorError.noGeneration
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.trackID, $0) })
        let tracks = slots.compactMap { byID[$0.trackID] }
        guard slot >= 0, slot < tracks.count else { throw PlaylistGeneratorError.noGeneration }

        let current = tracks[slot]
        let used = Set(tracks.map(\.trackID)).subtracting([current.trackID])
        var rng = SplitMix64(seed: request.randomSeed
            &+ UInt64(bitPattern: Int64(slot)) &* 0x9E37_79B9_7F4A_7C15)
        var best: (track: TrackFeatures, cost: Double, tie: UInt64)?

        for candidate in candidates
        where !used.contains(candidate.trackID) && candidate.trackID != current.trackID
            && !request.locks.values.contains(candidate.trackID) {
            var trial = tracks
            trial[slot] = candidate
            guard PlaylistSequencer.validateSpacing(trial, constraints: request.constraints) else {
                continue
            }
            var cost = PlaylistSequencer.arcError(
                energy: candidate.energy ?? PlaylistSequencer.neutral,
                position: slot, count: tracks.count, arc: request.arc)
            if slot > 0 {
                cost += PlaylistSequencer.transitionCost(tracks[slot - 1], candidate,
                                                         request.constraints)
            }
            if slot < tracks.count - 1 {
                cost += PlaylistSequencer.transitionCost(candidate, tracks[slot + 1],
                                                         request.constraints)
            }
            let tie = rng.next()
            if let existing = best {
                if cost < existing.cost || (cost == existing.cost && tie < existing.tie) {
                    best = (candidate, cost, tie)
                }
            } else {
                best = (candidate, cost, tie)
            }
        }
        guard let chosen = best else { throw PlaylistGeneratorError.noGeneration }

        var newTracks = tracks
        newTracks[slot] = chosen.track
        let newSlots = makeSlots(tracks: newTracks, request: request,
                                 semanticScores: semanticScores)
        let result = makeResult(slots: newSlots, candidates: newTracks, request: request)
        let items = makeItems(slots: newSlots, locks: request.locks)
        let persisted = try await persist(request: request, result: result, items: items)

        lastRequest = request
        lastBriefID = persisted.brief.id
        lastSlots = newSlots
        lastSemanticScores = semanticScores
        return PlaylistGeneration(brief: persisted.brief,
                                  result: persisted.result,
                                  items: persisted.items,
                                  requestedCount: newTracks.count,
                                  candidateCount: candidates.count,
                                  isShortPool: false)
    }

    /// Extend by `minutes`: the arc is re-parameterised over the new length
    /// (§28A.4), so extending a wind-down continues it rather than restarting it.
    public func extend(minutes: Int) async throws -> PlaylistGeneration {
        guard var request = lastRequest else { throw PlaylistGeneratorError.noGeneration }
        request.targetSeconds = (request.targetSeconds ?? 0) + Double(max(minutes, 1)) * 60
        return try await generate(request)
    }

    /// Reshuffle the middle: re-run the beam over `[from, to]` with the tracks
    /// outside it fixed as endpoints, on a fresh seed so the middle varies (§28A.4).
    public func reshuffle(from: Int, to: Int) async throws -> PlaylistGeneration {
        guard var request = lastRequest, let slots = lastSlots else {
            throw PlaylistGeneratorError.noGeneration
        }
        let lower = max(0, min(from, slots.count - 1))
        let upper = max(lower, min(to, slots.count - 1))
        var locks = request.locks
        for (index, slot) in slots.enumerated() where index < lower || index > upper {
            locks[index] = slot.trackID
        }
        request.locks = locks
        var rng = SplitMix64(seed: request.randomSeed)
        request.randomSeed = rng.next()
        return try await generate(request)
    }

    /// Save the latest sequence as a static playlist (FR-PLIST-7); links it on
    /// the brief's latest result and returns the new playlist id.
    @discardableResult
    public func saveAsPlaylist(title: String) async throws -> Int64 {
        guard let briefID = lastBriefID, let slots = lastSlots else {
            throw PlaylistGeneratorError.noGeneration
        }
        return try repository.savePlaylist(title: title, briefID: briefID, slots: slots)
    }

    // MARK: - Resolution (§28A.3 step 1, plan §2.7)

    private struct ResolvedCandidates {
        var candidates: [TrackFeatures]
        var semanticScores: [Int64: Double]
        var requestedCount: Int
        var isShortPool: Bool
        var slotZeroLock: Int64?
    }

    private func resolve(request: PlaylistGenerationRequest) async throws -> ResolvedCandidates {
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

    // MARK: - Candidate loading (core catalog)

    /// One core track's raw attributes, batch-loaded for candidate scoring —
    /// `track`/`asset`/`discovery_track_analysis`/`discovery_embedding`, the
    /// SAME core tables `VibeSearchModel`/`SmartCrateRepository` read.
    private struct CoreTrackData {
        var durationSec: Double
        var artistId: Int64?
        var albumId: Int64?
        var genre: String?
        var bpm: Double?
        var camelot: String?
        var energy: Double?
        var embedding: [Float]?
        var isFullyCached = false
    }

    private func loadCoreTrackData(for ids: [Int64]) async throws -> [Int64: CoreTrackData] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try await library.dbQueue.read { db -> [Int64: CoreTrackData] in
            var result: [Int64: CoreTrackData] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id AS id, t.durationSec AS durationSec, t.artistId AS artistId,
                       t.albumId AS albumId, t.genre AS genre,
                       a.bpm AS bpm, a.key AS camelot, a.energy AS energy
                FROM track t LEFT JOIN discovery_track_analysis a ON a.trackId = t.id
                WHERE t.id IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            for row in rows {
                let id: Int64 = row["id"]
                result[id] = CoreTrackData(durationSec: row["durationSec"] ?? 0,
                                           artistId: row["artistId"],
                                           albumId: row["albumId"],
                                           genre: row["genre"],
                                           bpm: row["bpm"],
                                           camelot: row["camelot"],
                                           energy: row["energy"],
                                           embedding: nil)
            }
            let embeddingRows = try Row.fetchAll(db, sql: """
                SELECT trackId, quantizedVector, scale FROM discovery_embedding
                WHERE trackId IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            for row in embeddingRows {
                let id: Int64 = row["trackId"]
                let data: Data = row["quantizedVector"]
                let scale: Double = row["scale"]
                let int8 = data.map { Int8(bitPattern: $0) }
                result[id]?.embedding = VectorQuantization.dequantize(int8, scale: Float(scale))
            }
            let cachedRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT trackId FROM asset WHERE trackId IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            for row in cachedRows {
                let id: Int64 = row["trackId"]
                result[id]?.isFullyCached = true
            }
            return result
        }
    }

    /// The retrieved pool's candidate features, with the two constraints the
    /// unified engine doesn't natively cover (genre exclusion, cache
    /// requirement — DJ-preparation-specific, not part of the shared
    /// scope/BPM/key contract) applied as a post-filter, same as before.
    private func loadCandidates(ids: [Int64], constraints: SequencingConstraints) async throws
        -> [TrackFeatures] {
        guard !ids.isEmpty else { return [] }
        let data = try await loadCoreTrackData(for: ids)
        var out: [TrackFeatures] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            guard let info = data[id] else { continue }
            if constraints.requireCached && !info.isFullyCached { continue }
            if !constraints.excludeGenres.isEmpty, let genre = info.genre,
               constraints.excludeGenres.contains(genre) {
                continue
            }
            out.append(TrackFeatures(trackID: id,
                                     durationSec: info.durationSec,
                                     bpm: info.bpm,
                                     camelot: info.camelot.flatMap(CamelotKey.init(code:)),
                                     energy: info.energy,
                                     embedding: info.embedding,
                                     artistIDs: info.artistId.map { [$0] } ?? [],
                                     albumID: info.albumId,
                                     isExplicit: false,
                                     isFullyCached: info.isFullyCached))
        }
        return out
    }

    /// The audio-seed track's own features — always included regardless of
    /// constraints (it is forced into the locked slot 0, mirroring the old
    /// pipeline's unconditional append).
    private func loadSeedFeatures(_ trackID: Int64) async throws -> TrackFeatures? {
        let data = try await loadCoreTrackData(for: [trackID])
        guard let info = data[trackID] else { return nil }
        return TrackFeatures(trackID: trackID,
                             durationSec: info.durationSec,
                             bpm: info.bpm,
                             camelot: info.camelot.flatMap(CamelotKey.init(code:)),
                             energy: info.energy,
                             embedding: info.embedding,
                             artistIDs: info.artistId.map { [$0] } ?? [],
                             albumID: info.albumId,
                             isExplicit: false,
                             isFullyCached: info.isFullyCached)
    }

    // MARK: - Output

    private func makeResult(slots: [SequencedSlot], candidates: [TrackFeatures],
                            request: PlaylistGenerationRequest) -> AutoPlaylistResult {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.trackID, $0) })
        let totalSeconds = slots.reduce(0) {
            $0 + Int((byID[$1.trackID]?.durationSec ?? 0).rounded())
        }
        let arcErrors = slots.compactMap { slot -> Double? in
            guard let actual = slot.actualEnergy else { return nil }
            return abs(actual - slot.targetEnergy)
        }
        let arcError = arcErrors.isEmpty ? 0 : arcErrors.reduce(0, +) / Double(arcErrors.count)
        let costs = slots.dropFirst().map(\.transitionCostIn)
        let meanTransitionCost = costs.isEmpty ? 0 : costs.reduce(0, +) / Double(costs.count)

        return AutoPlaylistResult(briefID: 0,
                                  playlistID: nil,
                                  smartCrateID: nil,
                                  generatedAt: Date(),
                                  totalSeconds: totalSeconds,
                                  arcError: arcError,
                                  meanTransitionCost: meanTransitionCost,
                                  analysisVersion: AnalysisVersions.embedding)
    }

    private func makeItems(slots: [SequencedSlot], locks: [Int: Int64]) -> [AutoPlaylistItem] {
        slots.map { slot in
            AutoPlaylistItem(resultID: 0,
                             trackID: slot.trackID,
                             position: slot.position,
                             locked: locks[slot.position] != nil,
                             targetEnergy: slot.targetEnergy,
                             actualEnergy: slot.actualEnergy ?? PlaylistSequencer.neutral,
                             transitionCostIn: slot.transitionCostIn,
                             semanticScore: slot.semanticScore)
        }
    }

    private func makeSlots(tracks: [TrackFeatures], request: PlaylistGenerationRequest,
                           semanticScores: [Int64: Double]) -> [SequencedSlot] {
        let arcTarget = (0..<tracks.count).map { index -> Double in
            let t = tracks.count > 1 ? Double(index) / Double(tracks.count - 1) : 0
            return request.arc.value(at: t)
        }
        return tracks.enumerated().map { index, track in
            SequencedSlot(position: index,
                          trackID: track.trackID,
                          targetEnergy: arcTarget[index],
                          actualEnergy: track.energy,
                          transitionCostIn: index == 0 ? 0
                            : PlaylistSequencer.transitionCost(tracks[index - 1], track,
                                                               request.constraints),
                          semanticScore: semanticScores[track.trackID] ?? PlaylistSequencer.neutral)
        }
    }

    // MARK: - Persist

    private func persist(request: PlaylistGenerationRequest, result: AutoPlaylistResult,
                         items: [AutoPlaylistItem]) async throws
        -> (brief: AutoPlaylistBrief, result: AutoPlaylistResult, items: [AutoPlaylistItem]) {
        let existingID = lastBriefID
        return try await pool.write { db in
            let now = Date()
            var brief: AutoPlaylistBrief
            if let existingID, let existing = try AutoPlaylistBrief.fetchOne(db, key: existingID) {
                brief = existing
                brief.prompt = request.prompt
                brief.arcKind = request.arc.kindCode
                brief.arcPointsJSON = request.arc.pointsJSON
                brief.targetSeconds = request.targetSeconds.map { Int($0.rounded()) }
                brief.targetTrackCount = request.targetTrackCount
                brief.constraintsJSON = try request.constraints.encodedJSONString()
                brief.seedTrackID = request.seedTrackID
                brief.seedCrateID = request.seedCrateID
                brief.randomSeed = Int64(bitPattern: request.randomSeed)
                brief.updatedAt = now
                try brief.update(db)
            } else {
                brief = AutoPlaylistBrief(syncID: UUID().uuidString,
                                          prompt: request.prompt,
                                          arcKind: request.arc.kindCode,
                                          arcPointsJSON: request.arc.pointsJSON,
                                          targetSeconds: request.targetSeconds.map { Int($0.rounded()) },
                                          targetTrackCount: request.targetTrackCount,
                                          constraintsJSON: try request.constraints.encodedJSONString(),
                                          seedTrackID: request.seedTrackID,
                                          seedCrateID: request.seedCrateID,
                                          randomSeed: Int64(bitPattern: request.randomSeed),
                                          createdAt: now,
                                          updatedAt: now)
                try brief.insert(db)
            }
            guard let briefID = brief.id else { throw PlaylistGeneratorError.persistFailed }
            var storedResult = result
            storedResult.briefID = briefID
            try storedResult.insert(db)
            guard let resultID = storedResult.id else { throw PlaylistGeneratorError.persistFailed }
            var storedItems: [AutoPlaylistItem] = []
            storedItems.reserveCapacity(items.count)
            for var item in items {
                item.resultID = resultID
                try item.insert(db)
                storedItems.append(item)
            }
            return (brief, storedResult, storedItems)
        }
    }
}
