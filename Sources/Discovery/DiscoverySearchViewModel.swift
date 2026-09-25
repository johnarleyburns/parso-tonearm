#if !os(watchOS)
import Combine
import Foundation
import ParsoAudioNeural
import TonearmCore

/// The `@MainActor ObservableObject` behind the Library search screen (plan
/// §10.1, C07). It owns ONLY cadence + plumbing: it builds a
/// `DiscoverySearchQuery` from its published input fields, hands it to the
/// portable `DiscoverySearchCoordinator` (250 ms debounce + generation guard —
/// plan §9) or the injected metadata-search closure, and maps every
/// `DiscoverySearchResponse` through the exhaustively-tested pure
/// `DiscoverySearchPresentation`. No scoring, validation or DB/model work
/// happens here or in any SwiftUI `body`.
///
/// Lives in `TonearmDiscovery` (not the app target) so it is unit-testable
/// without SwiftUI rendering.
@MainActor
public final class DiscoverySearchViewModel: ObservableObject {

    // MARK: - Inputs (bound by the view)

    /// metadata vs "Find by sound" (plan §10.1). Only affects how *text* is
    /// interpreted; BPM/key filters and scope apply in both.
    @Published public var inputMode: DiscoverySearchInputMode = .metadata { didSet { refresh() } }
    @Published public var searchText: String = "" { didSet { refresh() } }
    @Published public var scope: DiscoverySearchScope = .allMusic { didSet { refresh() } }
    @Published public var bpmMinText: String = "" { didSet { refresh() } }
    @Published public var bpmMaxText: String = "" { didSet { refresh() } }
    @Published public var compatibleKey: String = "" { didSet { refresh() } }
    @Published public var resultLimit: Int = ValidatedQuery.defaultLimit { didSet { refresh() } }

    @Published public private(set) var positiveRefinements: [String] = []
    @Published public private(set) var negativeRefinements: [String] = []
    /// Non-nil while in "More like this" mode. The reference track is excluded
    /// from its own results (plan §9).
    @Published public private(set) var referenceTrackID: Int64?
    /// Runtime-only anchor/option for the shared DJ-compatible match gate.
    /// These values are deliberately not part of `DiscoverySearchQuery`'s
    /// Codable saved-search payload.
    @Published public private(set) var matchingReferenceTrackID: Int64?
    @Published public private(set) var matchingTracksOnly = false

    // MARK: - Outputs (observed by the view)

    @Published public private(set) var screen: DiscoverySearchScreenState = .idle
    @Published public private(set) var results: [DiscoverySearchResult] = []
    @Published public private(set) var coverage: SearchRepository.Coverage?
    @Published public private(set) var lastResponse: DiscoverySearchResponse?

    // MARK: - Collaborators

    private let coordinator: DiscoverySearchCoordinator
    private let service: SearchService
    /// Existing metadata (title/artist) search — needs no model download
    /// (plan §9: "Existing metadata search remains usable without model
    /// download"). Scope-aware: the app applies the query's scope.
    private let metadataSearch: @Sendable (DiscoverySearchQuery) async -> Result<[TrackRow], any Error>
    private let onPlay: (DiscoverySearchResult) -> Void
    private let onAnalyzeTrack: (Int64) -> Void
    private let onDownloadModels: () -> Void
    private let onOpenIndexStatus: () -> Void

    /// Monotonic guard spanning BOTH the coordinator path and the metadata
    /// path, so a slow response from either never overwrites a newer query
    /// from the other (plan §9: "a cancelled / superseded query updates
    /// nothing").
    private var generation: Int64 = 0
    private var metadataTask: Task<Void, Never>?

    public init(
        coordinator: DiscoverySearchCoordinator,
        service: SearchService,
        metadataSearch: @escaping @Sendable (DiscoverySearchQuery) async -> Result<[TrackRow], any Error>,
        onPlay: @escaping (DiscoverySearchResult) -> Void,
        onAnalyzeTrack: @escaping (Int64) -> Void = { _ in },
        onDownloadModels: @escaping () -> Void = {},
        onOpenIndexStatus: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.service = service
        self.metadataSearch = metadataSearch
        self.onPlay = onPlay
        self.onAnalyzeTrack = onAnalyzeTrack
        self.onDownloadModels = onDownloadModels
        self.onOpenIndexStatus = onOpenIndexStatus
    }

    // MARK: - Query building

    /// The current `DiscoverySearchQuery` — exposed so a "Save this search"
    /// action can persist the exact Codable brief that produced the results
    /// (plan §9: one shared Codable contract).
    public func currentQuery() -> DiscoverySearchQuery {
        var sourceIDs: [Int64]?
        var playlistID: Int64?
        switch scope {
        case .allMusic: break
        case .sources(let ids): sourceIDs = ids
        case .playlist(let id): playlistID = id
        }
        let key = compatibleKey.trimmingCharacters(in: .whitespaces)
        return DiscoverySearchQuery(
            text: searchText,
            positiveRefinements: positiveRefinements,
            negativeRefinements: negativeRefinements,
            sourceIDs: sourceIDs,
            playlistID: playlistID,
            bpmMin: parseBPM(bpmMinText),
            bpmMax: parseBPM(bpmMaxText),
            compatibleKey: key.isEmpty ? nil : key,
            limit: resultLimit)
    }

    private func parseBPM(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // A non-empty but unparseable value becomes NaN so validation surfaces
        // `.bpmNotFinite` rather than silently ignoring the field (plan §9).
        return Double(trimmed) ?? .nan
    }

    // MARK: - Driving a query

    /// Rebuild the query from the current inputs and (re)run it. Cheap to call
    /// on every keystroke — the debounce + generation guard live below.
    public func refresh() {
        metadataTask?.cancel()
        generation &+= 1
        let gen = generation
        let query = currentQuery()

        // Trivial query with no explicit scope → the idle starting state, not
        // a needless browse round-trip.
        if referenceTrackID == nil, isTrivial(query) {
            Task { await coordinator.cancelPending() }
            results = []
            coverage = nil
            lastResponse = nil
            screen = .idle
            return
        }

        screen = .loading

        if let referenceTrackID {
            submitToCoordinator(query, referenceTrackID: referenceTrackID, gen: gen)
            return
        }

        if inputMode == .metadata, !normalizedText(query).isEmpty {
            runMetadata(query, gen: gen)
            return
        }

        // Find-by-sound text, or a filter-only / browse query (no model needed).
        submitToCoordinator(query, referenceTrackID: nil, gen: gen)
    }

    private func submitToCoordinator(
        _ query: DiscoverySearchQuery, referenceTrackID: Int64?, gen: Int64
    ) {
        Task { [weak self] in
            guard let self else { return }
            await self.coordinator.submit(
                query,
                referenceTrackID: referenceTrackID,
                matchingReferenceTrackID: self.matchingReferenceTrackID,
                matchingTracksOnly: self.matchingTracksOnly) { response in
                Task { @MainActor [weak self] in
                    self?.apply(response, gen: gen)
                }
            }
        }
    }

    private func runMetadata(_ query: DiscoverySearchQuery, gen: Int64) {
        // Surface BPM/key/limit validation issues even on the metadata path.
        if case .failure(let failure) = ValidatedQuery.validate(query) {
            results = []
            screen = .validationError(failure.issues)
            return
        }
        let search = metadataSearch
        let service = self.service
        metadataTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: DiscoverySearchCoordinator.debounceInterval)
            if Task.isCancelled { return }
            let outcome = await search(query)
            if Task.isCancelled { return }
            switch outcome {
            case .failure:
                await MainActor.run { [weak self] in self?.applyMetadataFailure(gen: gen) }
            case .success(var rows):
                // A hard BPM/key filter narrows the metadata hits through the
                // SAME shared retrieval primitive (plan §9), needing no model.
                if query.bpmMin != nil || query.bpmMax != nil || query.compatibleKey != nil {
                    var filterOnly = query
                    filterOnly.text = ""
                    filterOnly.positiveRefinements = []
                    filterOnly.negativeRefinements = []
                    let allowed = Set(await service.candidateTrackIDs(filterOnly))
                    rows = rows.filter { allowed.contains($0.id) }
                }
                if self.matchingTracksOnly, let referenceID = self.matchingReferenceTrackID {
                    let allowed = Set(await service.matchingTrackIDs(
                        query, referenceTrackID: referenceID))
                    rows = rows.filter { allowed.contains($0.id) }
                }
                let snapshot = rows
                await MainActor.run { [weak self] in self?.applyMetadata(snapshot, gen: gen) }
            }
        }
    }

    // MARK: - Applying responses

    private func apply(_ response: DiscoverySearchResponse, gen: Int64) {
        guard gen == generation else { return }  // superseded — update nothing
        lastResponse = response
        coverage = response.coverage
        if response.state == .cancelled {
            // Defensive: the coordinator normally never delivers this.
            screen = .staleSuppressed
            return
        }
        results = response.results
        screen = DiscoverySearchPresentation.make(from: response)
    }

    private func applyMetadata(_ rows: [TrackRow], gen: Int64) {
        guard gen == generation else { return }
        results = rows.map {
            DiscoverySearchResult(track: $0, similarity: nil, finalScore: nil, breakdown: nil)
        }
        coverage = nil
        lastResponse = nil
        screen = rows.isEmpty
            ? .noMatches(kind: .metadataBrowse)
            : .results(kind: .metadataBrowse, count: rows.count, stillIndexing: false)
    }

    private func applyMetadataFailure(gen: Int64) {
        guard gen == generation else { return }
        results = []
        screen = .searchFailed
    }

    // MARK: - Refinement chips (plan §10.1 "More like / Less like")

    public func addMoreLike(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !positiveRefinements.contains(t) else { return }
        positiveRefinements.append(t)
        refresh()
    }

    public func addLessLike(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !negativeRefinements.contains(t) else { return }
        negativeRefinements.append(t)
        refresh()
    }

    public func removeMoreLike(_ term: String) {
        positiveRefinements.removeAll { $0 == term }
        refresh()
    }

    public func removeLessLike(_ term: String) {
        negativeRefinements.removeAll { $0 == term }
        refresh()
    }

    public func clearRefinements() {
        guard !positiveRefinements.isEmpty || !negativeRefinements.isEmpty else { return }
        positiveRefinements = []
        negativeRefinements = []
        refresh()
    }

    // MARK: - "More like this" / Now Playing → similar

    /// From a result row or from Now Playing: switch to similar-track mode for
    /// `trackID`, excluding it from its own results (plan §9). Text and
    /// refinements are cleared; scope and BPM/key filters are kept.
    public func moreLikeThis(trackID: Int64) {
        referenceTrackID = trackID
        matchingReferenceTrackID = trackID
        searchText = ""
        positiveRefinements = []
        negativeRefinements = []
        refresh()
    }

    public func exitSimilarMode() {
        guard referenceTrackID != nil else { return }
        referenceTrackID = nil
        matchingReferenceTrackID = nil
        matchingTracksOnly = false
        refresh()
    }

    /// Sets a live playback anchor without replacing the semantic query with
    /// similar-track mode. Used by Mood and by its Keep Playing continuation.
    public func setMatchingReferenceTrackID(_ trackID: Int64?, enabled: Bool = true) {
        let usable = trackID.flatMap { $0 > 0 ? $0 : nil }
        let shouldEnable = enabled && usable != nil
        guard matchingReferenceTrackID != usable || matchingTracksOnly != shouldEnable else { return }
        matchingReferenceTrackID = usable
        matchingTracksOnly = shouldEnable
        refresh()
    }

    public func setMatchingTracksOnly(_ enabled: Bool) {
        guard matchingTracksOnly != enabled else { return }
        matchingTracksOnly = enabled
        refresh()
    }

    // MARK: - Row + banner actions

    public func play(_ result: DiscoverySearchResult) { onPlay(result) }

    /// "Analyze this track" for a stale/missing reference embedding (plan §9).
    public func analyzeReference() {
        if case .analyzeReference(let trackID) = screen, trackID > 0 {
            onAnalyzeTrack(trackID)
        }
    }

    /// "Download models" from the `modelMissing` state (plan §10.1).
    public func downloadModels() { onDownloadModels() }

    /// Link to the sound-index status screen (plan §10.1 / §10.2).
    public func openIndexStatus() { onOpenIndexStatus() }

    /// Retry after `.searchFailed`.
    public func retry() { refresh() }

    // MARK: - Helpers

    private func normalizedText(_ query: DiscoverySearchQuery) -> String {
        query.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isTrivial(_ query: DiscoverySearchQuery) -> Bool {
        normalizedText(query).isEmpty
            && query.positiveRefinements.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && query.negativeRefinements.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && query.bpmMin == nil && query.bpmMax == nil
            && query.compatibleKey == nil
            && query.sourceIDs == nil
            && query.playlistID == nil
    }

    /// Score-detail components for a result row (plan §10.1). Pure pass-through
    /// to the tested `RankBreakdownDisplay`.
    public func scoreComponents(for result: DiscoverySearchResult) -> [RankBreakdownDisplay.Component] {
        RankBreakdownDisplay.components(for: result)
    }
}

/// Lets a `QueueSource.mood(...)` queue (`Sources/Audio/AudioPlayer+
/// QueueSource.swift`, TonearmCore — see that file's doc comment for why
/// this conformance lives here instead of a direct type reference) reach
/// back into whichever `DiscoverySearchViewModel` instance is actually
/// running the Listen tab's mood query, from anywhere in the app.
extension DiscoverySearchViewModel: MoodQuerySource {
    public func addPositiveTerm(_ term: String) {
        addMoreLike(term)
    }

    /// Re-runs the current query and returns a fresh batch of tracks —
    /// reuses the exact same `SearchService` this view model already talks
    /// to, never a second search implementation (docs/plans/mood-based-
    /// listening-plan.md §3.3).
    public func refreshedTracks() async -> [TrackRow] {
        let response = await service.search(
            currentQuery(), referenceTrackID: referenceTrackID,
            matchingReferenceTrackID: matchingReferenceTrackID,
            matchingTracksOnly: matchingTracksOnly)
        return response.results.map(\.track)
    }

    public func setMatchingAnchor(_ trackID: Int64?) {
        setMatchingReferenceTrackID(trackID, enabled: trackID != nil)
    }
}
#endif
