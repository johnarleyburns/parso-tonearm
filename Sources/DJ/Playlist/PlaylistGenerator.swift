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
///
/// Split across files by concern (see `PlaylistGenerator+Interactions.swift`,
/// `PlaylistGenerator+Resolution.swift`, `PlaylistGenerator+CandidateLoading.swift`,
/// `PlaylistGenerator+Output.swift`); the properties below are shared state
/// read/written from several of those files, so they are `internal` (not
/// `private`) — Swift's `private` is scoped to this file only.
public actor PlaylistGenerator {
    /// DJ-local: `auto_playlist_brief/result/item` persistence, `smart_crate`
    /// lookups for `seedCrateID`. NOT the core catalog.
    public let pool: DatabasePool
    /// The ONE core music catalog (plan §3) — candidate features, embeddings,
    /// musical analysis.
    let library: LibraryStore
    let searchService: SearchService
    let repository: AutoPlaylistRepository

    /// The last completed generation, for reject / replace / extend / reshuffle.
    var lastRequest: PlaylistGenerationRequest?
    var lastBriefID: Int64?
    var lastCandidates: [TrackFeatures]?
    var lastSlots: [SequencedSlot]?
    var lastSemanticScores: [Int64: Double]?

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
}
