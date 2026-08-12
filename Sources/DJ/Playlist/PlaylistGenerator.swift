import Foundation
import GRDB

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
    /// "Start from a saved vibe": the crate's stored `VibeQuery` becomes the anchor.
    public var seedCrateID: Int64?
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
public actor PlaylistGenerator {
    public let pool: DatabasePool
    private let store: any VectorStore
    private let embedder: CLAPEmbedder
    private let repository: AutoPlaylistRepository

    /// The last completed generation, for reject / replace / extend / reshuffle.
    private var lastRequest: PlaylistGenerationRequest?
    private var lastBriefID: Int64?
    private var lastCandidates: [TrackFeatures]?
    private var lastSlots: [SequencedSlot]?
    private var lastSemanticScores: [Int64: Double]?

    public init(pool: DatabasePool, store: any VectorStore, embedder: CLAPEmbedder) {
        self.pool = pool
        self.store = store
        self.embedder = embedder
        self.repository = AutoPlaylistRepository(pool: pool)
    }

    // MARK: - Generate

    /// Full pipeline (§28A.3 step 1): resolve the anchor, scan the Tier A pool,
    /// apply hard constraints, subtract this brief's rejections, map energies to
    /// CDF ranks, run the pure beam search, and persist brief + result + items.
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
        let (anchor, slotZeroLock, audioSeeded) = try await anchorVector(for: request)

        let provisionalCount = request.targetTrackCount ?? PlaylistSequencer.maxTrackCount
        let topK = min(PlaylistSequencer.generatorPoolCap, max(8 * max(provisionalCount, 1), 1))

        var matches = try store.search(query: anchor, topK: topK, isCancelled: { false })
        if audioSeeded, let seedID = slotZeroLock {
            matches.removeAll { $0.trackID == seedID }
        }
        var candidates = try await loadCandidates(matches: matches,
                                                  constraints: request.constraints)

        let requestedCount = estimatedCount(request: request, candidates: candidates)

        // Short pool? Widen the semantic pool and re-filter before saying so —
        // never pad with tracks that don't fit (plan §2.7, FR-PLIST-2 honesty).
        if candidates.count < requestedCount {
            let widened = min(PlaylistSequencer.generatorPoolCap * 4, topK * 4)
            matches = try store.search(query: anchor, topK: widened, isCancelled: { false })
            if audioSeeded, let seedID = slotZeroLock {
                matches.removeAll { $0.trackID == seedID }
            }
            candidates = try await loadCandidates(matches: matches,
                                                  constraints: request.constraints)
        }

        let rejections = try await loadRejections()
        candidates.removeAll { rejections.contains($0.trackID) }
        let semanticScores = Dictionary(uniqueKeysWithValues:
            matches.map { ($0.trackID, Double($0.similarity)) })

        // Audio-seeded briefs pin their opening: the seed track joins the pool
        // (it may be outside the semantic pool) and is locked at slot 0.
        if let seedID = slotZeroLock, let seed = try await loadSeedFeatures(seedID) {
            candidates.append(seed)
        }

        let isShortPool = candidates.count < requestedCount
        return ResolvedCandidates(candidates: candidates,
                                  semanticScores: semanticScores,
                                  requestedCount: requestedCount,
                                  isShortPool: isShortPool,
                                  slotZeroLock: slotZeroLock)
    }

    /// The semantic anchor: a seed track's stored pooled vector (audio path —
    /// skips the text encoder), else a crate's stored query, else the prompt.
    private func anchorVector(for request: PlaylistGenerationRequest) async throws
        -> (vector: [Float], slotZeroLock: Int64?, audioSeeded: Bool) {
        if let seedID = request.seedTrackID {
            if let stored = try await loadEmbedding(trackID: seedID) {
                let vector = Quantization.dequantize(stored.int8Vector,
                                                     scale: Float(stored.scale))
                return (vector, seedID, true)
            }
            if let crateID = request.seedCrateID, let query = try await crateQuery(id: crateID),
               query.hasContent {
                return (try await embedQuery(query, request: request), nil, false)
            }
            if !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (try await embedPrompt(request), nil, false)
            }
            throw PlaylistGeneratorError.noAnchor
        }
        if let crateID = request.seedCrateID, let query = try await crateQuery(id: crateID),
           query.hasContent {
            return (try await embedQuery(query, request: request), nil, false)
        }
        if !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (try await embedPrompt(request), nil, false)
        }
        throw PlaylistGeneratorError.noAnchor
    }

    private func embedPrompt(_ request: PlaylistGenerationRequest) async throws -> [Float] {
        var vec = [Float](repeating: 0, count: embedder.spec.dimensions)
        let text = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { vec = try await embedder.embedText(text) }
        for term in request.positiveTerms {
            let termVector = try await embedder.embedText(term)
            vec = Pooling.l2Normalized(zip(vec, termVector).map(+))
        }
        for term in request.negativeTerms {
            let termVector = try await embedder.embedText(term)
            vec = Pooling.l2Normalized(zip(vec, termVector).map { $0 - $1 })
        }
        return vec
    }

    private func embedQuery(_ query: VibeQuery, request: PlaylistGenerationRequest) async throws
        -> [Float] {
        var vec = [Float](repeating: 0, count: embedder.spec.dimensions)
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { vec = try await embedder.embedText(text) }
        for term in query.positiveTerms + request.positiveTerms {
            let termVector = try await embedder.embedText(term)
            vec = Pooling.l2Normalized(zip(vec, termVector).map(+))
        }
        for term in query.negativeTerms + request.negativeTerms {
            let termVector = try await embedder.embedText(term)
            vec = Pooling.l2Normalized(zip(vec, termVector).map { $0 - $1 })
        }
        return vec
    }

    private func crateQuery(id: Int64) async throws -> VibeQuery? {
        try await pool.read { db in
            guard let crate = try SmartCrate.fetchOne(db, key: id) else { return nil }
            return try VibeQuery.decodeJSON(crate.queryJSON)
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

    // MARK: - Candidate loading

    private func loadCandidates(matches: [VectorMatch],
                                constraints: SequencingConstraints) async throws -> [TrackFeatures] {
        let ids = matches.map(\.trackID)
        guard !ids.isEmpty else { return [] }
        let rows = try await pool.read { db in
            try DJTrack.filter(ids.contains(Column("id"))).fetchAll(db)
        }
        var rowsByID: [Int64: DJTrack] = [:]
        for row in rows { if let id = row.id { rowsByID[id] = row } }

        let artistIDs = try await trackArtistIDs(for: ids)
        let genreNames = try await trackGenreNames(for: ids)
        let embeddings = try await trackEmbeddings(for: ids)
        let cached = try await cachedTrackIDs(ids)

        return matches.compactMap { match in
            guard let row = rowsByID[match.trackID] else { return nil }
            let bpm = row.bpm ?? row.detectedBPM
            if let range = constraints.bpmRange {
                guard let bpm, range.contains(bpm) else { return nil }
            }
            if constraints.requireCached && !cached.contains(match.trackID) { return nil }
            if !constraints.excludeGenres.isEmpty,
               let genres = genreNames[match.trackID],
               genres.contains(where: { constraints.excludeGenres.contains($0) }) {
                return nil
            }
            // M3: the DJ schema carries no explicit flag (plan §3.3), so
            // `allowExplicit` is honoured structurally but is a no-op in practice.
            let embedding = embeddings[match.trackID]
                .map { Quantization.dequantize($0.int8Vector, scale: Float($0.scale)) }
            return TrackFeatures(trackID: match.trackID,
                                 durationSec: row.durationSec ?? 0,
                                 bpm: bpm,
                                 camelot: row.camelot.flatMap(CamelotKey.init(code:)),
                                 energy: row.energy,
                                 embedding: embedding,
                                 artistIDs: artistIDs[match.trackID] ?? [],
                                 albumID: row.albumID,
                                 isExplicit: false,
                                 isFullyCached: cached.contains(match.trackID))
        }
    }

    private func loadSeedFeatures(_ trackID: Int64) async throws -> TrackFeatures? {
        try await pool.read { db -> TrackFeatures? in
            guard let row = try DJTrack.filter(Column("id") == trackID).fetchOne(db) else {
                return nil
            }
            var artistIDs: [Int64] = []
            let artistRows = try Row.fetchAll(db, sql: """
                SELECT artistID FROM track_artist WHERE trackID = ? ORDER BY position
                """, arguments: [trackID])
            for artistRow in artistRows {
                if let id: Int64 = artistRow["artistID"] { artistIDs.append(id) }
            }
            let embedding = try DJTrackEmbedding.filter(Column("trackID") == trackID).fetchOne(db)
            return TrackFeatures(trackID: trackID,
                                 durationSec: row.durationSec ?? 0,
                                 bpm: row.bpm ?? row.detectedBPM,
                                 camelot: row.camelot.flatMap(CamelotKey.init(code:)),
                                 energy: row.energy,
                                 embedding: embedding.map {
                                     Quantization.dequantize($0.int8Vector,
                                                            scale: Float($0.scale))
                                 },
                                 artistIDs: artistIDs,
                                 albumID: row.albumID,
                                 isExplicit: false,
                                 isFullyCached: true)
        }
    }

    private func loadEmbedding(trackID: Int64) async throws -> DJTrackEmbedding? {
        try await pool.read { db in
            try DJTrackEmbedding.filter(Column("trackID") == trackID).fetchOne(db)
        }
    }

    private func trackArtistIDs(for trackIDs: [Int64]) async throws -> [Int64: [Int64]] {
        guard !trackIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: trackIDs.count).joined(separator: ",")
        return try await pool.read { db in
            var result: [Int64: [Int64]] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT trackID, artistID FROM track_artist
                WHERE trackID IN (\(placeholders)) ORDER BY trackID, position
                """, arguments: StatementArguments(trackIDs))
            for row in rows {
                let trackID: Int64 = row["trackID"]
                let artistID: Int64 = row["artistID"]
                result[trackID, default: []].append(artistID)
            }
            return result
        }
    }

    private func trackGenreNames(for trackIDs: [Int64]) async throws -> [Int64: [String]] {
        guard !trackIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: trackIDs.count).joined(separator: ",")
        return try await pool.read { db in
            var result: [Int64: [String]] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT tg.trackID AS trackID, g.name AS name
                FROM track_genre tg JOIN genre g ON g.id = tg.genreID
                WHERE tg.trackID IN (\(placeholders))
                """, arguments: StatementArguments(trackIDs))
            for row in rows {
                let trackID: Int64 = row["trackID"]
                let name: String = row["name"]
                result[trackID, default: []].append(name)
            }
            return result
        }
    }

    private func trackEmbeddings(for trackIDs: [Int64]) async throws -> [Int64: DJTrackEmbedding] {
        guard !trackIDs.isEmpty else { return [:] }
        let rows = try await pool.read { db in
            try DJTrackEmbedding.filter(trackIDs.contains(Column("trackID"))).fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.trackID, $0) })
    }

    private func cachedTrackIDs(_ trackIDs: [Int64]) async throws -> Set<Int64> {
        guard !trackIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: trackIDs.count).joined(separator: ",")
        return try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT trackID FROM asset WHERE trackID IN (\(placeholders))
                """, arguments: StatementArguments(trackIDs))
            return Set(rows.compactMap { row -> Int64? in
                if let id: Int64 = row["trackID"] { return id }
                return nil
            })
        }
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
