import Foundation
import GRDB
import Combine
import TonearmCore
import TonearmDiscovery

/// The search seam the Vibe Search view model talks to (§41.4 "SearchModel ▸
/// SearchService"). C02 (IMPLEMENT_CLAP_PLAN.md, Slice B): re-pointed at the
/// unified-catalog `SearchService`/`DiscoverySearchQuery` contract instead of
/// the deleted DJ-local `SemanticSearchService`/`VectorStore` stack — the same
/// engine `Sources/Features/Discovery/DiscoverySearchView.swift` uses, fixing
/// the old stack's real bugs (top-400-before-filter, filter-only rejected, no
/// selected-source scope, cancellation always false) for free. `SearchService`
/// conforms via the extension below; tests inject a controllable fake so
/// debounce/cancel/absence are exercised deterministically on macOS.
public protocol VibeSearching: Sendable {
    func search(
        _ query: DiscoverySearchQuery,
        referenceTrackID: Int64?,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> DiscoverySearchResponse
}

extension SearchService: VibeSearching {}

/// A compact summary of the library's own descriptor distribution — what the
/// suggestion chips are seeded from (mockup `ipad/04a`), never a hard-coded list.
public struct LibraryDescriptorSummary: Sendable, Equatable {
    public var bpm: [Double]
    public var energy: [Double]
    public var durationSec: [Double]
    public var camelotCounts: [String: Int]

    public init(bpm: [Double] = [],
                energy: [Double] = [],
                durationSec: [Double] = [],
                camelotCounts: [String: Int] = [:]) {
        self.bpm = bpm
        self.energy = energy
        self.durationSec = durationSec
        self.camelotCounts = camelotCounts
    }
}

/// Pure, deterministic chips derived from a library's own descriptors
/// (NFR-DET-3): median tempo band, dominant Camelot, energy and duration. These
/// read as the user's music rather than a copy-written list.
public enum SuggestionChips {

    public static func seed(from summary: LibraryDescriptorSummary,
                            limit: Int = 4) -> [String] {
        var chips: [String] = []

        if let median = median(summary.bpm) {
            let rounded = median.rounded()
            if rounded >= 118 && rounded <= 132 {
                chips.append("steady around \(Int(rounded)) BPM")
            } else if rounded < 118 {
                chips.append("slow and deep")
            } else {
                chips.append("fast and relentless")
            }
        }

        if let dominant = summary.camelotCounts.max(by: {
            ($0.value, $0.key) < ($1.value, $1.key)
        }) {
            chips.append("in \(dominant.key)")
        }

        if let meanEnergy = mean(summary.energy) {
            if meanEnergy >= 7 {
                chips.append("high energy")
            } else if meanEnergy <= 3.5 {
                chips.append("low-key")
            } else {
                chips.append("mid-energy")
            }
        }

        if let meanDuration = mean(summary.durationSec) {
            if meanDuration < 210 {
                chips.append("shorter tracks")
            } else if meanDuration > 330 {
                chips.append("long-form tracks")
            }
        }

        return Array(chips.prefix(limit))
    }

    /// Read the distribution straight from the ONE core library (C02): track
    /// duration from core `track`, bpm/energy/camelot from the core
    /// `discovery_track_analysis` side table — one cheap aggregate query, no
    /// object graph, no DJ-local `track.bpm/energy/camelot` columns.
    public static func summary(library: LibraryStore) async -> LibraryDescriptorSummary {
        let rows = (try? await library.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.durationSec AS durationSec, a.bpm AS bpm,
                       a.energy AS energy, a.key AS camelot
                FROM track t LEFT JOIN discovery_track_analysis a ON a.trackId = t.id
                """)
        }) ?? []
        var bpm: [Double] = []
        bpm.reserveCapacity(rows.count)
        var energy: [Double] = []
        energy.reserveCapacity(rows.count)
        var duration: [Double] = []
        duration.reserveCapacity(rows.count)
        var counts: [String: Int] = [:]
        for row in rows {
            if let value: Double = row["bpm"] { bpm.append(value) }
            if let value: Double = row["energy"] { energy.append(value) }
            if let value: Double = row["durationSec"] { duration.append(value) }
            if let key: String = row["camelot"] { counts[key, default: 0] += 1 }
        }
        return LibraryDescriptorSummary(bpm: bpm, energy: energy,
                                        durationSec: duration, camelotCounts: counts)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// View model for Vibe Search (§41.4/41.5, mockups `ipad/04a`+`04b`, `iphone/02`).
/// Free tier. Owns debounced querying (250 ms, in-flight cancel via a
/// generation guard — §27.5), honest coverage (FR-SEM-8), suggestion-chip
/// seeding from the library's own descriptors, the stated model-not-downloaded
/// state (FR-SEM-6) with an ODR fetch, +/− refinement (FR-SEM-4), audio-to-audio
/// "more like this" (FR-SEM-7), and saving the query as a smart crate
/// (FR-SEM-5). The privacy line is stated once, on first use (NFR-PRIV-5).
///
/// C02: results are core `TrackRow`/`track.id` (`DiscoverySearchResult`), never
/// a `DJTrackRow`/DJ-local id — consistent with `DeckLoader`/`LibraryModel`/
/// `GigCrateRepository`. `DiscoverySearchResult` carries no musical attributes
/// of its own (unlike the old DJ-local `DJTrackRow`), so `analysisByTrackID` is
/// hydrated separately from core `discovery_track_analysis` for display.
@MainActor
public final class VibeSearchModel: ObservableObject {

    public let searchService: any VibeSearching
    public let repository: SmartCrateRepository
    private let resource: ModelResourceService
    private let library: LibraryStore
    private let debounceNanoseconds: UInt64
    private let resultLimit: Int
    private let defaults: UserDefaults

    @Published public var queryText: String = ""
    @Published public private(set) var positiveTerms: [String] = []
    @Published public private(set) var negativeTerms: [String] = []
    @Published public private(set) var response: DiscoverySearchResponse?
    @Published public private(set) var isSearching = false
    @Published public private(set) var suggestionChips: [String] = []
    @Published public private(set) var coverage: (indexed: Int, total: Int) = (0, 0)
    @Published public private(set) var textModelAvailable = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var savedCrate: SmartCrate?
    @Published public private(set) var privacyAcknowledged: Bool
    /// bpm/camelot per core track id, for the current `response.results`
    /// (fetched from core `discovery_track_analysis` — see type doc).
    @Published public private(set) var analysisByTrackID: [Int64: (bpm: Double?, camelot: String?)] = [:]

    /// Hooks the presenter wires to real playback (§41.5 Play · Queue).
    public var onPlay: (([DiscoverySearchResult]) -> Void)?
    public var onQueue: (([DiscoverySearchResult]) -> Void)?

    public static let privacyKey = "vibeSearch.privacyAcknowledged"

    private var searchTask: Task<Void, Never>?
    private var generation = 0

    public init(searchService: any VibeSearching,
                repository: SmartCrateRepository,
                resource: ModelResourceService,
                library: LibraryStore,
                debounceNanoseconds: UInt64 = 250_000_000,
                resultLimit: Int = 100,
                defaults: UserDefaults = .standard,
                privacyAcknowledged: Bool? = nil) {
        self.searchService = searchService
        self.repository = repository
        self.resource = resource
        self.library = library
        self.debounceNanoseconds = debounceNanoseconds
        self.resultLimit = resultLimit
        self.defaults = defaults
        let stored = defaults.bool(forKey: Self.privacyKey)
        self.privacyAcknowledged = privacyAcknowledged ?? stored
    }

    /// The crate-able query for the current field + chips (FR-SEM-5).
    public var currentQuery: DiscoverySearchQuery {
        DiscoverySearchQuery(text: queryText,
                             positiveRefinements: positiveTerms,
                             negativeRefinements: negativeTerms,
                             limit: resultLimit)
    }

    // MARK: - Startup / refresh

    public func start() async {
        textModelAvailable = await resource.isAvailable(.clapText)
        await refreshCoverage()
        await refreshSuggestions()
    }

    /// Honest coverage (FR-SEM-8): an ordinary unscoped query's own
    /// `DiscoverySearchResponse.coverage` (indexed ÷ total in scope) — the
    /// same coverage every `SearchService` caller gets, not a separate cache.
    public func refreshCoverage() async {
        let result = await searchService.search(
            DiscoverySearchQuery(limit: ValidatedQuery.minLimit),
            referenceTrackID: nil, isCancelled: { false })
        if let c = result.coverage {
            coverage = (indexed: c.indexed, total: c.totalInScope)
        }
    }

    public func refreshSuggestions() async {
        suggestionChips = SuggestionChips.seed(
            from: await SuggestionChips.summary(library: library))
    }

    /// NFR-PRIV-5: stated once, on first use; remembered so it is not repeated.
    public func acknowledgePrivacy() {
        privacyAcknowledged = true
        defaults.set(true, forKey: Self.privacyKey)
    }

    // MARK: - Query input (debounced, §27.5)

    public func updateQuery(_ text: String) {
        queryText = text
        scheduleSearch(after: debounceNanoseconds)
    }

    public func addPositiveTerm(_ term: String) {
        positiveTerms.append(term)
        scheduleSearch(after: 0)
    }

    public func removePositiveTerm(_ term: String) {
        positiveTerms.removeAll { $0 == term }
        scheduleSearch(after: 0)
    }

    public func addNegativeTerm(_ term: String) {
        negativeTerms.append(term)
        scheduleSearch(after: 0)
    }

    public func removeNegativeTerm(_ term: String) {
        negativeTerms.removeAll { $0 == term }
        scheduleSearch(after: 0)
    }

    public func searchImmediately() {
        scheduleSearch(after: 0)
    }

    /// Debounce: each keystroke cancels the previous pending search and starts a
    /// fresh one after the window. An in-flight search is effectively
    /// abandoned — its stale result is discarded by the generation guard below
    /// (the outer Task itself is also cancelled, same as before this rewire).
    private func scheduleSearch(after delay: UInt64) {
        searchTask?.cancel()
        generation += 1
        let thisGeneration = generation
        searchTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.runSearch(generation: thisGeneration)
        }
    }

    private func runSearch(generation: Int) async {
        guard generation == self.generation else { return }
        isSearching = true
        defer { isSearching = false }
        let result = await searchService.search(currentQuery, referenceTrackID: nil,
                                                 isCancelled: { false })
        guard generation == self.generation else { return }
        response = result
        lastError = errorMessage(for: result.state)
        await hydrateAnalysis(for: result.results)
    }

    // MARK: - Audio-to-audio (FR-SEM-7)

    /// "More like this track": the reference track's own stored embedding
    /// drives the scan directly (`SearchService`'s `.similar` mode), excluding
    /// itself (§27.5).
    public func searchSimilar(to trackID: Int64) async {
        searchTask?.cancel()
        generation += 1
        let thisGeneration = generation
        isSearching = true
        defer { isSearching = false }
        let result = await searchService.search(
            DiscoverySearchQuery(limit: resultLimit),
            referenceTrackID: trackID, isCancelled: { false })
        guard thisGeneration == self.generation else { return }
        response = result
        lastError = errorMessage(for: result.state)
        await hydrateAnalysis(for: result.results)
    }

    // MARK: - ODR fetch (FR-SEM-6)

    /// Offer the download, never silent empty results. After the tag lands, the
    /// query re-runs.
    public func fetchTextModel() async {
        await resource.retain(.clapText)
        textModelAvailable = await resource.isAvailable(.clapText)
        if textModelAvailable {
            scheduleSearch(after: 0)
        }
    }

    // MARK: - Smart crate (FR-SEM-5)

    /// Save the current query as a crate; returns the new crate id.
    @discardableResult
    public func saveAsSmartCrate(name: String) throws -> Int64 {
        let id = try repository.save(query: currentQuery, name: name)
        savedCrate = try repository.crate(id: id)
        return id
    }

    // MARK: - Result analysis hydration

    /// `DiscoverySearchResult` carries a core `TrackRow`, which (unlike the old
    /// DJ-local `DJTrackRow`) has no bpm/camelot of its own — batch-read them
    /// from core `discovery_track_analysis` for the results currently shown.
    private func hydrateAnalysis(for results: [DiscoverySearchResult]) async {
        let ids = results.map(\.trackID)
        guard !ids.isEmpty else {
            analysisByTrackID = [:]
            return
        }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = (try? await library.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT trackId, bpm, key FROM discovery_track_analysis
                WHERE trackId IN (\(placeholders))
                """, arguments: StatementArguments(ids))
        }) ?? []
        var built: [Int64: (bpm: Double?, camelot: String?)] = [:]
        for row in rows {
            let id: Int64 = row["trackId"]
            let bpm: Double? = row["bpm"]
            let camelot: String? = row["key"]
            built[id] = (bpm, camelot)
        }
        analysisByTrackID = built
    }

    /// A real error/absence state surfaced as text; `.ready`/`.noMatches`/the
    /// stated model-absent and unindexed-reference states already have their
    /// own explicit UI treatment in `VibeSearchView` and are not errors.
    private func errorMessage(for state: DiscoverySearchResponse.State) -> String? {
        switch state {
        case .searchFailed:
            return "Search failed — please try again."
        case .validationFailed(let issues):
            return issues.map(\.description).joined(separator: " ")
        default:
            return nil
        }
    }
}

/// Assembles the production Vibe Search stack (§41.4 View ▸ VM ▸ data): the
/// unified `SearchService` (C02) + the DJ-local `SmartCrateRepository`
/// (`smart_crate`/`crate_rule` are DJ-only operational data, intentionally
/// still DJ-local per the plan amendment — the same decision session 12 made
/// for `GridCorrectionRepository`/`MixRepository`). A dedicated `VectorIndex`/
/// `ModelManager` is built per screen rather than sharing the app's one
/// process-wide `DiscoveryAssembly` (owned by the App target, not reachable
/// from this package) — a real, flagged duplication (mirrors the CLAP text
/// model being loaded twice if both this screen and the core Discovery search
/// screen are used in one session), not fixed here to keep this change scoped.
/// Absence is honest (FR-SEM-6): until the `clap-text` ODR tag is fetched
/// (through the SAME `BundleResourceProvider`/tag the old stack used — ODR
/// content mounts into `Bundle.main` regardless of which request triggered
/// it), `ModelManager.textEncoder` fails with `.resourcesUnavailable` and
/// every query lands in the stated model-not-downloaded state — the view
/// turns that into an explicit fetch offer, never a silent empty list.
@MainActor
public enum VibeSearchAssembly {

    public static func makeModel(pool: DatabasePool, library: LibraryStore = .shared) async -> VibeSearchModel {
        let provider = BundleResourceProvider()
        let resource = ModelResourceService(provider: provider)
        let writer = await library.dbQueue
        let index = VectorIndex(writer: writer)
        let models = ModelManager(resourceProvider: {
            let dirs = [Bundle.main.resourceURL].compactMap { $0 }
            return ModelResourceLocator(searchDirectories: dirs).resolve()
        })
        let service = SearchService(writer: writer, index: index, models: models)
        return VibeSearchModel(searchService: service,
                               repository: SmartCrateRepository(pool: pool),
                               resource: resource,
                               library: library)
    }
}
