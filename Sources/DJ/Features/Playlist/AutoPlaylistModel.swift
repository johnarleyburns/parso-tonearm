import Foundation
import Combine
import GRDB

/// The generation seam the auto-playlist view model talks to (plan §3.4, §41.6
/// "PlaylistBriefView ▸ AutoPlaylistModel ▸ PlaylistGenerator"). `PlaylistGenerator`
/// conforms; tests inject a controllable fake so generating / result / short-pool
/// states are exercised deterministically on macOS.
public protocol AutoPlaylistGenerating: Sendable {
    /// Full pipeline: resolve candidates → CDF ranks → pure beam search → persist.
    func generate(_ request: PlaylistGenerationRequest) async throws -> PlaylistGeneration
    /// Row into `auto_playlist_rejection`, then re-run with the remaining locks.
    func reject(trackID: Int64) async throws -> PlaylistGeneration
    /// Re-run one slot only, holding neighbours fixed (§28A.4).
    func replaceSlot(slot: Int) async throws -> PlaylistGeneration
    /// Re-parameterise the arc over the new length and continue (§28A.4).
    func extend(minutes: Int) async throws -> PlaylistGeneration
    /// Re-run the beam over `[from, to]` with the boundaries fixed (§28A.4).
    func reshuffle(from: Int, to: Int) async throws -> PlaylistGeneration
    /// Save the latest sequence as a static playlist (FR-PLIST-7).
    @discardableResult
    func saveAsPlaylist(title: String) async throws -> Int64
}

extension PlaylistGenerator: AutoPlaylistGenerating {}

/// One row of the generated sequence for the result view (mockup `ipad/05b`,
/// `iphone/03`): the persisted item joined with the track's display metadata.
/// `transitionCostIn` is the cost from the previous slot (0 at the head).
public struct AutoPlaylistRow: Identifiable, Sendable, Equatable {
    public var position: Int
    public var trackID: Int64
    public var title: String
    public var artistNames: String
    public var bpm: Double?
    public var camelot: String?
    /// The [0,1] arc value asked for at this slot (§28A.5).
    public var targetEnergy: Double
    /// The track's empirical-CDF energy rank, [0,1].
    public var actualEnergy: Double
    public var transitionCostIn: Double
    public var semanticScore: Double
    public var locked: Bool
    /// True for an audio-seeded brief's pinned opening slot.
    public var isSeed: Bool

    public init(position: Int,
                trackID: Int64,
                title: String,
                artistNames: String,
                bpm: Double? = nil,
                camelot: String? = nil,
                targetEnergy: Double,
                actualEnergy: Double,
                transitionCostIn: Double,
                semanticScore: Double,
                locked: Bool,
                isSeed: Bool = false) {
        self.position = position
        self.trackID = trackID
        self.title = title
        self.artistNames = artistNames
        self.bpm = bpm
        self.camelot = camelot
        self.targetEnergy = targetEnergy
        self.actualEnergy = actualEnergy
        self.transitionCostIn = transitionCostIn
        self.semanticScore = semanticScore
        self.locked = locked
        self.isSeed = isSeed
    }

    public var id: Int64 { trackID }
}

/// View model for the auto-playlist brief + result (plan §3.4, §41.6–41.7,
/// §42.4; mockups `ipad/05a`, `ipad/05b`, `iphone/03`). Free tier. Phone and
/// iPad share the one model.
///
/// Owns the brief field and the editable "what we understood" chips (§28A.6),
/// the energy-arc picker, the length (duration with ±5% honesty, or a track
/// count), the constraint toggles, the optional seed track, and every FR-PLIST-6
/// interaction (lock / reject / replace / extend / reshuffle) — each a
/// constrained re-run of the generator, never a fresh roll. Generation state is
/// honest: `isGenerating`, an error, or the result including the short-pool
/// disclosure (plan §2.7). FR-PLIST-10's "Blend these" card is session-scoped:
/// dismissed once, it does not reappear for the life of this model.
@MainActor
public final class AutoPlaylistModel: ObservableObject {

    public let generator: any AutoPlaylistGenerating
    public let crateRepository: SmartCrateRepository
    private let trackRepository: DJTrackRepository

    // MARK: Brief

    /// The whole brief, edited freely; re-parsed into chips on every change.
    @Published public var prompt: String = "" {
        didSet { refreshParse() }
    }
    /// The editable "what we understood" chips — a chip the user removes stays
    /// removed for this prompt (the extractor's claim is then dropped).
    @Published public private(set) var chips: [BriefChip] = []
    /// The energy-arc picker; snapped to the parse's arc phrase when detected.
    @Published public var arc: EnergyArc = .build

    // MARK: Length (FR-PLIST-2's T)

    /// Duration mode (slider, 30 min…4 h) vs a fixed track count.
    @Published public var useTrackCount = false
    /// Target duration in seconds; the ±5% honesty note rides on this.
    @Published public var targetSeconds: Double = 2 * 3600
    @Published public var targetTrackCount: Double = 30

    // MARK: Constraints (§28A.2)

    @Published public var minArtistGap: Int = 3
    @Published public var minAlbumGap: Int = 2
    @Published public var maxBPMJump: Double = 8.0
    @Published public var keyStrictness: Double = 0.6
    @Published public var requireCached = false
    @Published public var allowExplicit = true

    // MARK: Seed track (§41.6 "Start from")

    @Published public private(set) var seedTrackID: Int64?
    @Published public private(set) var seedTrackLabel: String?

    // MARK: Generation state

    @Published public private(set) var isGenerating = false
    @Published public private(set) var generation: PlaylistGeneration?
    @Published public private(set) var rows: [AutoPlaylistRow] = []
    @Published public private(set) var lastError: String?
    /// Wall time of the last generation, milliseconds (mockup "1.9 s" chip).
    @Published public private(set) var lastGenerationMillis: Double?
    /// How many tracks the user has rejected against this brief this session.
    @Published public private(set) var rejectionCount = 0
    @Published public private(set) var savedPlaylistID: Int64?
    @Published public private(set) var savedCrateID: Int64?

    /// Hooks the presenter wires to real playback (§41.7 Play).
    public var onPlay: (([AutoPlaylistRow]) -> Void)?

    // MARK: FR-PLIST-10 (session-scoped)

    @Published public private(set) var blendCardDismissed = false

    /// The inert "Blend these" card shows only while a result exists and has
    /// not been dismissed this session (the MUST-NOT-reappear clause, plan §2.10).
    public var showsBlendCard: Bool { generation != nil && !blendCardDismissed }

    // MARK: Private

    private var parse = BriefParse()
    private var removedChipIDs: Set<String> = []
    private var parsedBPM: (lo: Double?, hi: Double?)?
    private var locks: [Int: Int64] = [:]
    private var generationCount: UInt64 = 0

    public init(generator: any AutoPlaylistGenerating,
                crateRepository: SmartCrateRepository,
                trackRepository: DJTrackRepository) {
        self.generator = generator
        self.crateRepository = crateRepository
        self.trackRepository = trackRepository
    }

    // MARK: - Brief → request

    /// The generation request the current brief + form edits describe. The seed
    /// is deterministic (a fixed fold of the prompt mixed with the generation
    /// count), so two devices with the same brief and same sequence of
    /// generations agree (NFR-DET-1); the count is what makes "regenerate" vary.
    public var currentRequest: PlaylistGenerationRequest {
        PlaylistGenerationRequest(prompt: prompt,
                                  positiveTerms: chips.filter { $0.kind == .positive }
                                      .map(\.label),
                                  negativeTerms: chips.filter { $0.kind == .negative }
                                      .map(\.label),
                                  arc: arc,
                                  targetSeconds: useTrackCount ? nil : targetSeconds,
                                  targetTrackCount: useTrackCount
                                      ? max(1, Int(targetTrackCount)) : nil,
                                  constraints: currentConstraints,
                                  seedTrackID: seedTrackID,
                                  randomSeed: currentSeed,
                                  locks: locks)
    }

    /// The crate-able query for the current brief + chips (§41.7 "Save as Smart
    /// Crate" — the brief becomes a `VibeQuery` the crate keeps re-evaluating).
    public var currentQuery: VibeQuery {
        VibeQuery(text: prompt,
                  positiveTerms: chips.filter { $0.kind == .positive }.map(\.label),
                  negativeTerms: chips.filter { $0.kind == .negative }.map(\.label),
                  bpmRange: bpmRange,
                  limit: 100)
    }

    public var currentConstraints: SequencingConstraints {
        SequencingConstraints(minArtistGap: minArtistGap,
                              minAlbumGap: minAlbumGap,
                              maxBPMJump: maxBPMJump,
                              keyStrictness: keyStrictness,
                              allowExplicit: allowExplicit,
                              requireCached: requireCached,
                              bpmRange: bpmRange)
    }

    /// The parse's BPM range while a bpm chip is still present.
    private var bpmRange: ClosedRange<Double>? {
        guard let parsedBPM, let lo = parsedBPM.lo, let hi = parsedBPM.hi, lo <= hi
        else { return nil }
        return lo...hi
    }

    /// Deterministic FNV-1a fold of the prompt (never Swift's per-process
    /// `hashValue` — invariant §49.3.2), mixed with the generation count so a
    /// fresh "generate" varies while staying reproducible for the same sequence.
    private var currentSeed: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in prompt.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1_0000_0001_b3
        }
        return hash &+ generationCount &* 0x9E37_79B9_7F4A_7C15
    }

    // MARK: - Prompt → chips (§28A.6)

    private func refreshParse() {
        parse = BriefExtractor.parse(prompt)
        chips = parse.chips.filter { !removedChipIDs.contains($0.id) }
        if let duration = parse.targetSeconds, containsChip(.duration) {
            if !useTrackCount { targetSeconds = duration }
        }
        if let count = parse.targetTrackCount, containsChip(.trackCount) {
            targetTrackCount = Double(count)
            useTrackCount = true
        }
        if let detected = parse.arc, containsChip(.arc) {
            arc = detected
        }
        if parse.bpmLo != nil || parse.bpmHi != nil, containsChip(.bpm) {
            parsedBPM = (parse.bpmLo, parse.bpmHi)
        }
        if let explicit = parse.allowExplicit {
            allowExplicit = explicit
        }
    }

    /// Remove a chip: the extractor's claim is dropped for this prompt. A term
    /// chip stops reaching the request; the bpm chip clears the BPM range; a
    /// count chip returns the length control to duration mode. The arc picker
    /// stays the user's (removing an arc chip only hides the parse's claim).
    public func removeChip(_ chip: BriefChip) {
        removedChipIDs.insert(chip.id)
        switch chip.kind {
        case .bpm: parsedBPM = nil
        case .trackCount: useTrackCount = false
        case .duration, .arc, .positive, .negative: break
        }
        chips = parse.chips.filter { !removedChipIDs.contains($0.id) }
    }

    private func containsChip(_ kind: BriefChip.Kind) -> Bool {
        chips.contains { $0.kind == kind }
    }

    // MARK: - Seed track

    public func setSeed(trackID: Int64, label: String) {
        seedTrackID = trackID
        seedTrackLabel = label
    }

    public func clearSeed() {
        seedTrackID = nil
        seedTrackLabel = nil
    }

    /// The library the seed picker searches over (§41.6 "Start from").
    public func tracks(matching text: String) -> [DJTrackRow] {
        (try? trackRepository.tracks(matching: LibraryQuery(searchText: text))) ?? []
    }

    // MARK: - Generation

    /// Run the full pipeline (§41.6 Generate). Sets honest states: generating,
    /// error, or the result with its rows and short-pool disclosure.
    public func generate() async {
        await run { try await generator.generate(currentRequest) }
    }

    /// Pin / unpin a slot (FR-PLIST-6). The lock rides on the next constrained
    /// re-run; the row's lock state reflects `currentRequest.locks`.
    public func toggleLock(at position: Int) {
        guard let item = generation?.items.first(where: { $0.position == position }) else { return }
        if locks[position] != nil {
            locks[position] = nil
        } else {
            locks[position] = item.trackID
        }
        rebuildRows()
    }

    public func isLocked(at position: Int) -> Bool {
        locks[position] != nil
    }

    public func reject(trackID: Int64) async {
        if await run({ try await generator.reject(trackID: trackID) }) {
            rejectionCount += 1
        }
    }

    public func replaceSlot(slot: Int) async {
        await run { try await generator.replaceSlot(slot: slot) }
    }

    public func extend(minutes: Int) async {
        await run { try await generator.extend(minutes: minutes) }
    }

    public func reshuffle(from: Int, to: Int) async {
        await run { try await generator.reshuffle(from: from, to: to) }
    }

    /// Save the latest sequence as a static playlist (FR-PLIST-7).
    public func saveAsPlaylist(title: String) async {
        guard generation != nil else { return }
        do {
            savedPlaylistID = try await generator.saveAsPlaylist(title: title)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Save the brief as a smart crate — the crate IS the query, not a copy
    /// (§41.7, FR-SEM-5's repository).
    public func saveAsSmartCrate(name: String) {
        do {
            savedCrateID = try crateRepository.save(query: currentQuery, name: name)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - FR-PLIST-10

    public func dismissBlendCard() {
        blendCardDismissed = true
    }

    // MARK: - Result summary

    public var resultTitle: String { Self.title(for: prompt) }
    public var totalSeconds: Int { generation?.result.totalSeconds ?? 0 }
    public var arcError: Double? { generation.map { $0.result.arcError } }
    public var meanTransitionCost: Double? { generation.map { $0.result.meanTransitionCost } }
    public var isShortPool: Bool { generation?.isShortPool ?? false }
    public var requestedCount: Int { generation?.requestedCount ?? 0 }
    public var candidateCount: Int { generation?.candidateCount ?? 0 }

    /// The target the footer measures against (FR-PLIST-2): the duration the
    /// brief asked for, or the fixed track count.
    public var targetSummaryText: String {
        useTrackCount ? "\(requestedCount) tracks"
            : Self.durationText(targetSeconds)
    }

    /// (total − target) / target as a signed percent, duration mode only.
    public var durationDeltaPercent: Double? {
        guard !useTrackCount, targetSeconds > 0, generation != nil else { return nil }
        return (Double(totalSeconds) - targetSeconds) / targetSeconds * 100
    }

    /// The "1.9 s" generation-time chip (mockup `ipad/05b`).
    public var generationSecondsText: String? {
        guard let millis = lastGenerationMillis else { return nil }
        return String(format: "%.1f s", millis / 1000)
    }

    /// A "2:00:00" / "45:00" duration label shared by brief and result.
    public static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return String(format: "%d:%02d:00", hours, minutes) }
        return String(format: "%d:00", minutes)
    }

    /// AT-PLIST-3's user-facing footer line ("52% smoother than shuffle").
    /// Nil until commit 3.5's shuffle-comparison harness supplies the baseline
    /// over the same track set — the footer never invents a number.
    public var smootherThanShuffleText: String? { nil }

    /// The result header's title from the brief — the first four words, extended
    /// past a trailing article so it never ends on "a"/"an"/"the". Reads like the
    /// mockup's "Dinner, then not dinner". Deterministic.
    public static func title(for prompt: String) -> String {
        let words = prompt.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return "Generated playlist" }
        var count = min(4, words.count)
        if ["a", "an", "the"].contains(words[count - 1].lowercased()), words.count > count {
            count += 1
        }
        let joined = words.prefix(count).joined(separator: " ").lowercased()
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    // MARK: - Private plumbing

    /// One guarded, state-honest generation-style operation.
    @discardableResult
    private func run(_ operation: () async throws -> PlaylistGeneration) async -> Bool {
        guard !isGenerating else { return false }
        isGenerating = true
        lastError = nil
        let startedAt = Date()
        defer { isGenerating = false }
        do {
            let result = try await operation()
            generationCount += 1
            await rebuildRows(from: result)
            lastGenerationMillis = Date().timeIntervalSince(startedAt) * 1000
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func rebuildRows() {
        guard let generation else { rows = []; return }
        let ids = generation.items.map(\.trackID)
        let tracks = (try? trackRepository.tracks(ids: ids)) ?? []
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        rows = generation.items.map { item in
            let track = byID[item.trackID]
            return AutoPlaylistRow(position: item.position,
                                   trackID: item.trackID,
                                   title: track?.title ?? "Track \(item.trackID)",
                                   artistNames: track?.artistNames ?? "",
                                   bpm: track?.bpm,
                                   camelot: track?.camelot,
                                   targetEnergy: item.targetEnergy,
                                   actualEnergy: item.actualEnergy,
                                   transitionCostIn: item.transitionCostIn ?? 0,
                                   semanticScore: item.semanticScore,
                                   locked: isLocked(at: item.position),
                                   isSeed: seedTrackID != nil && item.trackID == seedTrackID
                                       && item.position == 0)
        }
    }

    private func rebuildRows(from result: PlaylistGeneration) async {
        generation = result
        rebuildRows()
    }
}

/// Assembles the production auto-playlist stack (§41.6 View ▸ VM ▸ data): the
/// Tier A store + the real CLAP text encoder behind ODR delivery, exactly as
/// `VibeSearchAssembly` does — the generator reuses the same embedder seam.
@MainActor
public enum AutoPlaylistAssembly {

    public static func makeModel(pool: DatabasePool) -> AutoPlaylistModel? {
        let spec = EmbeddingModelSpec.musicCLAPMetadata
        guard let store = try? VectorStoreTierA(pool: pool, dims: spec.dimensions) else {
            return nil
        }
        let encoder = CoreMLSemanticModel(kind: .text,
                                          url: modelURL(named: "CLAPTextEncoder.mlpackage"),
                                          spec: spec)
        let embedder = CLAPEmbedder(model: encoder)
        let generator = PlaylistGenerator(pool: pool, store: store, embedder: embedder)
        return AutoPlaylistModel(generator: generator,
                                 crateRepository: SmartCrateRepository(pool: pool),
                                 trackRepository: DJTrackRepository(pool: pool))
    }

    /// The on-disk location the ODR tag lands at. Before the tag is fetched this
    /// path doesn't exist, which is exactly the honest absence `isAvailable()`
    /// reports (mirrors `BundleResourceProvider.url(for:)`).
    private static func modelURL(named name: String) -> URL {
        let path = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.main.url(forResource: path, withExtension: ext)
            ?? Bundle.main.resourceURL?.appendingPathComponent(name)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }
}
