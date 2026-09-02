import Foundation
import GRDB
import Combine

/// The search seam the Vibe Search view model talks to (§41.4 "SearchModel ▸
/// SearchService"). `SemanticSearchService` conforms; tests inject a controllable
/// fake so debounce/cancel/absence are exercised deterministically on macOS.
public protocol VibeSearching: Sendable {
    /// Text → embed (with +/− refine terms) → Tier A pool → hybrid re-rank.
    func search(_ query: VibeQuery) async throws -> SearchResponse
    /// Audio-to-audio "more like this" (FR-SEM-7), self-excluding.
    func similar(to trackID: Int64, limit: Int) async throws -> SearchResponse
    /// Indexed ÷ total tracks, honest (FR-SEM-8).
    func coverageCounts() async -> (indexed: Int, total: Int)
}

extension SemanticSearchService: VibeSearching {}

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

    /// Read the distribution straight from the DJ library — one cheap aggregate
    /// query per descriptor, no object graph.
    public static func summary(pool: DatabasePool) async -> LibraryDescriptorSummary {
        let rows = (try? pool.read { db in
            try Row.fetchAll(db, sql: "SELECT bpm, energy, durationSec, camelot FROM track")
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
/// Free tier. Owns debounced querying (250 ms, in-flight cancel — §27.5), honest
/// coverage (FR-SEM-8), suggestion-chip seeding from the library's own
/// descriptors, the stated model-not-downloaded state (FR-SEM-6) with an ODR
/// fetch, +/− refinement (FR-SEM-4), audio-to-audio "more like this" (FR-SEM-7),
/// and saving the query as a smart crate (FR-SEM-5). The privacy line is stated
/// once, on first use (NFR-PRIV-5).
@MainActor
public final class VibeSearchModel: ObservableObject {

    public let searchService: any VibeSearching
    public let repository: SmartCrateRepository
    private let resource: ModelResourceService
    private let pool: DatabasePool
    private let debounceNanoseconds: UInt64
    private let resultLimit: Int
    private let defaults: UserDefaults

    @Published public var queryText: String = ""
    @Published public private(set) var positiveTerms: [String] = []
    @Published public private(set) var negativeTerms: [String] = []
    @Published public private(set) var response: SearchResponse?
    @Published public private(set) var isSearching = false
    @Published public private(set) var suggestionChips: [String] = []
    @Published public private(set) var coverage: (indexed: Int, total: Int) = (0, 0)
    @Published public private(set) var textModelAvailable = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var savedCrate: SmartCrate?
    @Published public private(set) var privacyAcknowledged: Bool

    /// Hooks the presenter wires to real playback (§41.5 Play · Queue).
    public var onPlay: (([SearchResult]) -> Void)?
    public var onQueue: (([SearchResult]) -> Void)?

    public static let privacyKey = "vibeSearch.privacyAcknowledged"

    private var searchTask: Task<Void, Never>?
    private var generation = 0

    public init(searchService: any VibeSearching,
                repository: SmartCrateRepository,
                resource: ModelResourceService,
                pool: DatabasePool,
                debounceNanoseconds: UInt64 = 250_000_000,
                resultLimit: Int = 100,
                defaults: UserDefaults = .standard,
                privacyAcknowledged: Bool? = nil) {
        self.searchService = searchService
        self.repository = repository
        self.resource = resource
        self.pool = pool
        self.debounceNanoseconds = debounceNanoseconds
        self.resultLimit = resultLimit
        self.defaults = defaults
        let stored = defaults.bool(forKey: Self.privacyKey)
        self.privacyAcknowledged = privacyAcknowledged ?? stored
    }

    /// The crate-able query for the current field + chips (FR-SEM-5).
    public var currentQuery: VibeQuery {
        VibeQuery(text: queryText,
                  positiveTerms: positiveTerms,
                  negativeTerms: negativeTerms,
                  limit: resultLimit)
    }

    // MARK: - Startup / refresh

    public func start() async {
        textModelAvailable = await resource.isAvailable(.clapText)
        await refreshCoverage()
        await refreshSuggestions()
    }

    public func refreshCoverage() async {
        coverage = await searchService.coverageCounts()
    }

    public func refreshSuggestions() async {
        suggestionChips = SuggestionChips.seed(
            from: await SuggestionChips.summary(pool: pool))
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
    /// fresh one after the window. An in-flight embed is effectively abandoned —
    /// its stale result is discarded by the generation guard below.
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
        do {
            let result = try await searchService.search(currentQuery)
            guard generation == self.generation else { return }
            response = result
            lastError = nil
        } catch {
            guard generation == self.generation else { return }
            lastError = error.localizedDescription
        }
    }

    // MARK: - Audio-to-audio (FR-SEM-7)

    /// "More like this track": skip the text encoder entirely and use the track's
    /// own stored pooled vector, excluding itself (§27.5).
    public func searchSimilar(to trackID: Int64) async {
        searchTask?.cancel()
        generation += 1
        let thisGeneration = generation
        isSearching = true
        defer { isSearching = false }
        do {
            let result = try await searchService.similar(to: trackID, limit: resultLimit)
            guard thisGeneration == self.generation else { return }
            response = result
            lastError = nil
        } catch {
            guard thisGeneration == self.generation else { return }
            lastError = error.localizedDescription
        }
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
}

/// Assembles the production Vibe Search stack (§41.4 View ▸ VM ▸ data): Tier A
/// store + the real CLAP text encoder behind ODR delivery. Absence is honest
/// (FR-SEM-6): until the `clap-text` tag is fetched the encoder's URL doesn't
/// exist, so every query lands in the stated model-not-downloaded state — the
/// view turns that into an explicit fetch offer, never a silent empty list.
@MainActor
public enum VibeSearchAssembly {

    public static func makeModel(pool: DatabasePool) -> VibeSearchModel? {
        let provider = BundleResourceProvider()
        let resource = ModelResourceService(provider: provider)
        let spec = EmbeddingModelSpec.musicCLAPMetadata
        guard let store = try? VectorStoreTierA(pool: pool, dims: spec.dimensions) else {
            return nil
        }
        let encoder = CoreMLSemanticModel(kind: .text,
                                          url: modelURL(named: "CLAPTextEncoder.mlpackage"),
                                          spec: spec)
        let embedder = CLAPEmbedder(model: encoder)
        let service = SemanticSearchService(pool: pool, store: store,
                                            embedder: embedder, resource: resource)
        return VibeSearchModel(searchService: service,
                               repository: SmartCrateRepository(pool: pool),
                               resource: resource,
                               pool: pool)
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
