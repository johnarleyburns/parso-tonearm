import Foundation

/// What the listener asked Blend Lab for.
public struct BlendLabRequest: Sendable, Equatable {
    public var seedTrackIDs: [Int64]
    public var targetTrackCount: Int
    public var shape: MixShape
    /// When set, only these tracks may be used (a genre or playlist scope).
    public var allowedTrackIDs: Set<Int64>?
    /// When set, only tracks whose analysed BPM falls in this range may be used.
    public var bpmRange: ClosedRange<Double>?

    public init(seedTrackIDs: [Int64] = [], targetTrackCount: Int = 12, shape: MixShape = .steady,
                allowedTrackIDs: Set<Int64>? = nil, bpmRange: ClosedRange<Double>? = nil) {
        self.seedTrackIDs = seedTrackIDs
        self.targetTrackCount = targetTrackCount
        self.shape = shape
        self.allowedTrackIDs = allowedTrackIDs
        self.bpmRange = bpmRange
    }
}

/// Which part of the library a blend is created from, and the track-count
/// range that scope allows.
public enum BlendLabScope: String, CaseIterable, Sendable, Identifiable {
    case genre, playlist, all
    public var id: String { rawValue }

    public static let minTracks = 2
    public static let maxTracks = 10

    /// A BPM filter is valid when its lower bound does not exceed its upper bound.
    public static func isValidBPMRange(lower: Double, upper: Double) -> Bool { lower <= upper }

    /// Ids in scope after the optional inclusive BPM filter. A track with unknown BPM
    /// is excluded whenever `bpm` is set.
    public static func eligibleIDs(allowed: Set<Int64>?, library: [TrackRow], bpm: ClosedRange<Double>?,
                                   bpmByID: [Int64: Double]) -> Set<Int64> {
        Set(library.compactMap { row -> Int64? in
            guard let id = row.track.id else { return nil }
            if let allowed, !allowed.contains(id) { return nil }
            if let bpm, !(bpmByID[id].map(bpm.contains) ?? false) { return nil }
            return id
        })
    }

    /// Highest track count allowed for `available` tracks in scope: the smaller of that and 10.
    public static func maxTrackCount(available: Int) -> Int { min(maxTracks, available) }

    /// Clamps a requested count into the allowed range (never below 2).
    public static func clampedCount(_ count: Int, available: Int) -> Int {
        min(max(count, minTracks), max(minTracks, maxTrackCount(available: available)))
    }

    /// Sorted distinct non-empty genres across the library.
    public static func genres(in library: [TrackRow]) -> [String] {
        Array(Set(library.compactMap { $0.track.genre?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Ids of library tracks with exactly this genre.
    public static func trackIDs(genre: String, in library: [TrackRow]) -> Set<Int64> {
        Set(library.compactMap { row in
            row.track.genre?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(genre) == .orderedSame
                ? row.track.id : nil
        })
    }
}

/// What a generator produced. `isBasicMix` is true for the deterministic
/// catalog/library fallback, so the UI can say so honestly.
public struct BlendLabGeneration: Sendable {
    public var rows: [TrackRow]
    public var plan: MixPlan?
    public var isBasicMix: Bool

    public init(rows: [TrackRow], plan: MixPlan? = nil, isBasicMix: Bool) {
        self.rows = rows; self.plan = plan; self.isBasicMix = isBasicMix
    }
}

/// Deterministic library fallback: seeds first, then library order, no model.
public enum BlendLabFallback {
    public static func basicMix(_ request: BlendLabRequest, library: [TrackRow]) -> BlendLabGeneration {
        let library = request.allowedTrackIDs.map { allowed in
            library.filter { $0.track.id.map(allowed.contains) ?? false }
        } ?? library
        let seeds = request.seedTrackIDs.compactMap { id in library.first { $0.track.id == id } }
        let seedIDs = Set(seeds.compactMap(\.track.id))
        let rest = library.filter { row in row.track.id.map { !seedIDs.contains($0) } ?? true }
        let rows = Array((seeds + rest).prefix(max(1, request.targetTrackCount)))
        return BlendLabGeneration(rows: rows, plan: nil, isBasicMix: true)
    }
}

/// Create → preview → edit → save state for one Blend Lab visit. Every edit and
/// every generation start bumps `generation`; a generation that completes for
/// an older generation is discarded, so it can never overwrite newer edits.
@MainActor
public final class BlendLabSession: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case generating
        case ready
        case failed(String)
    }

    /// Returns a model-backed mix, or throws when the model is unavailable.
    public typealias Generate = @Sendable (BlendLabRequest) async throws -> BlendLabGeneration
    public typealias Play = @MainActor ([TrackRow]) -> Void

    /// "No blend" for an edge: the current engine's gapless style.
    public static let noBlendStyle = TransitionStyle.gapless.rawValue

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var document: BlendDocument?
    @Published public private(set) var rowsByOccurrence: [UUID: TrackRow] = [:]
    @Published public private(set) var isBasicMix = false
    @Published public private(set) var message: String?
    @Published public private(set) var savedID: UUID?
    /// Bumps on every edit, generation start and cancel.
    @Published public private(set) var generation = 0

    private let generate: Generate
    private let library: () -> [TrackRow]
    private let repository: BlendRepository
    private let play: Play
    private var task: Task<Void, Never>?
    private var request = BlendLabRequest()

    public init(generate: @escaping Generate, library: @escaping () -> [TrackRow],
                repository: BlendRepository, play: @escaping Play) {
        self.generate = generate; self.library = library
        self.repository = repository; self.play = play
    }

    /// Rows in document order (occurrences with no row are dropped).
    public var orderedRows: [(occurrenceID: UUID, row: TrackRow)] {
        (document?.occurrences ?? []).compactMap { occ in
            rowsByOccurrence[occ.id].map { (occ.id, $0) }
        }
    }

    public func start(_ request: BlendLabRequest) {
        self.request = request
        generation += 1
        let mine = generation
        task?.cancel()
        phase = .generating; message = nil
        task = Task { [weak self] in await self?.run(request, generation: mine) }
    }

    /// Runs one generation to completion (awaitable for tests).
    public func startAndWait(_ request: BlendLabRequest) async {
        start(request)
        await task?.value
    }

    public func regenerate() { start(request) }

    public func cancel() {
        generation += 1
        task?.cancel()
        phase = document == nil ? .idle : .ready
    }

    private func run(_ request: BlendLabRequest, generation mine: Int) async {
        var result: BlendLabGeneration
        var notice: String?
        do {
            result = try await generate(request)
        } catch is CancellationError {
            return
        } catch {
            result = BlendLabFallback.basicMix(request, library: library())
            notice = String(localized: "The sound model isn't available, so this is a basic mix from your library.")
        }
        // Late completion: an edit, cancel or newer generation owns the screen.
        guard mine == generation, !Task.isCancelled else { return }
        guard !result.rows.isEmpty else {
            phase = .failed(String(localized: "There are no playable tracks to blend yet. Add music and try again."))
            return
        }
        let doc = BlendReplay.document(from: result.rows, plan: result.plan,
                                       title: String(localized: "Blend Lab Mix"), origin: .blendLab)
        document = doc
        rowsByOccurrence = Dictionary(uniqueKeysWithValues: zip(doc.occurrences.map(\.id), result.rows))
        isBasicMix = result.isBasicMix
        savedID = nil
        message = notice ?? (result.isBasicMix
            ? String(localized: "Basic mix: tracks picked from your library without the sound model.") : nil)
        phase = .ready
        if result.rows.count == 1 {
            message = String(localized: "Only one track is available, so there is nothing to blend yet.")
        }
    }

    // MARK: Edits — each yields a new document generation.

    private func edit(_ change: (BlendDocument) -> BlendDocument) {
        guard let document else { return }
        task?.cancel()
        self.document = change(document)
        generation += 1
        savedID = nil
        phase = .ready
    }

    public func move(from: IndexSet, to: Int) {
        edit { doc in
            var occ = doc.occurrences
            let moving = from.sorted().map { occ[$0] }
            let before = from.filter { $0 < to }.count
            for i in from.sorted().reversed() { occ.remove(at: i) }
            occ.insert(contentsOf: moving, at: max(0, min(occ.count, to - before)))
            return doc.replacingOccurrences(occ)
        }
    }

    public func remove(occurrenceID: UUID) {
        edit { $0.replacingOccurrences($0.occurrences.filter { $0.id != occurrenceID }) }
        rowsByOccurrence[occurrenceID] = nil
    }

    /// Replaces one occurrence's source, keeping the occurrence's identity.
    public func replace(occurrenceID: UUID, with row: TrackRow) {
        edit { doc in
            var occ = doc.occurrences
            guard let i = occ.firstIndex(where: { $0.id == occurrenceID }) else { return doc }
            occ[i].source = BlendReplay.identity(of: row)
            return doc.replacingOccurrences(occ)
        }
        rowsByOccurrence[occurrenceID] = row
    }

    /// Candidates for Replace: library rows not already in this blend.
    public func replacementCandidates() -> [TrackRow] {
        let used = Set(rowsByOccurrence.values.compactMap(\.track.id))
        return library().filter { $0.track.id.map { !used.contains($0) } ?? false }
    }

    public func setNoBlend(afterOccurrence id: UUID, _ on: Bool) {
        edit { doc in
            var copy = doc
            guard let i = copy.edges.firstIndex(where: { $0.fromOccurrenceID == id }) else { return doc }
            copy.edges[i].requestedStyle = on ? Self.noBlendStyle : nil
            copy.generation += 1
            copy.updatedAt = Date()
            return copy
        }
    }

    // MARK: Play and save

    /// Hands the current ordered queue to the production player.
    public func playPreview(from index: Int = 0) {
        let rows = orderedRows.map(\.row)
        guard !rows.isEmpty else { return }
        play(Array(rows[min(index, rows.count - 1)...]))
    }

    public func save(title: String? = nil) async {
        guard var doc = document, doc.occurrences.count > 0 else { return }
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { doc.title = title }
        let mine = generation
        do {
            let stored = try await repository.save(doc)
            guard mine == generation else { return }  // edited while saving
            document = stored; savedID = stored.id
            message = String(localized: "Saved to My Music › Saved Blends.")
        } catch {
            message = String(localized: "Couldn't save this blend. Try again.")
        }
    }
}
