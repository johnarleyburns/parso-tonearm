import XCTest
import GRDB

@testable import TonearmDJ

/// VibeSearchModel (plan commit 2.5): debounce 250 ms with in-flight cancel
/// (§27.5), honest coverage (FR-SEM-8), stated model-absent state (FR-SEM-6)
/// with an ODR fetch, suggestion chips seeded from the library's own
/// descriptors, smart-crate save (FR-SEM-5), and the one-time privacy line
/// (NFR-PRIV-5).
@MainActor
final class SearchModelTests: XCTestCase {

    // MARK: - Fakes

    /// Records every query and answers from a scripted response queue.
    private final class RecordingSearch: VibeSearching, @unchecked Sendable {
        private let lock = NSLock()
        private var _queries: [VibeQuery] = []
        private var _responses: [SearchResponse] = []
        private var _coverage: (indexed: Int, total: Int)

        init(coverage: (indexed: Int, total: Int) = (0, 0)) {
            _coverage = coverage
        }

        /// NSLock can't be touched directly from async contexts; funnel every
        /// locked section through this synchronous helper.
        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        var queries: [VibeQuery] {
            withLock { _queries }
        }

        func setCoverage(_ value: (indexed: Int, total: Int)) {
            withLock { _coverage = value }
        }

        func enqueue(_ response: SearchResponse) {
            withLock { _responses.append(response) }
        }

        func search(_ query: VibeQuery) async throws -> SearchResponse {
            let scripted = withLock { () -> SearchResponse? in
                _queries.append(query)
                if !_responses.isEmpty { return _responses.removeFirst() }
                return nil
            }
            if let scripted { return scripted }
            let fraction = withLock { () -> Double in
                guard _coverage.total > 0 else { return 0 }
                return Double(_coverage.indexed) / Double(_coverage.total)
            }
            return SearchResponse(state: .ready, results: [], coverage: fraction,
                                  latencyMillis: 1)
        }

        func similar(to trackID: Int64, limit: Int) async throws -> SearchResponse {
            SearchResponse(state: .ready, results: [], coverage: 0, latencyMillis: 0)
        }

        func coverageCounts() async -> (indexed: Int, total: Int) {
            withLock { _coverage }
        }
    }

    /// Blocks the first search on a continuation so tests can observe a stale
    /// in-flight result and prove it is discarded. Latency encodes `text.count`
    /// so responses are distinguishable.
    private final class GatedSearch: VibeSearching, @unchecked Sendable {
        private let lock = NSLock()
        private var _queries: [VibeQuery] = []
        private var _pending: [CheckedContinuation<Void, Never>] = []
        private var _blockNext = true

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        var queries: [VibeQuery] {
            withLock { _queries }
        }

        func search(_ query: VibeQuery) async throws -> SearchResponse {
            let shouldBlock = withLock { () -> Bool in
                _queries.append(query)
                let block = _blockNext
                _blockNext = false
                return block
            }
            if shouldBlock {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withLock { _pending.append(continuation) }
                }
            }
            return SearchResponse(state: .ready, results: [], coverage: 1,
                                  latencyMillis: Double(query.text.count))
        }

        func releaseAll() {
            let pending = withLock { () -> [CheckedContinuation<Void, Never>] in
                let current = _pending
                _pending = []
                return current
            }
            for continuation in pending { continuation.resume() }
        }

        func similar(to trackID: Int64, limit: Int) async throws -> SearchResponse {
            SearchResponse(state: .ready, results: [], coverage: 1, latencyMillis: 0)
        }

        func coverageCounts() async -> (indexed: Int, total: Int) { (0, 0) }
    }

    /// Scripted ODR availability, deterministic for macOS `swift test`.
    private final class ScriptedProvider: ModelResourceProviding, @unchecked Sendable {
        let tagFileNames: [ModelTag: String] = [:]
        private let lock = NSLock()
        private var _available: [ModelTag: Bool]

        init(available: [ModelTag: Bool]) { _available = available }

        func setAvailable(_ tag: ModelTag, _ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            _available[tag] = value
        }
        func isAvailable(_ tag: ModelTag) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return _available[tag] ?? false
        }
        func url(for tag: ModelTag) async -> URL? { nil }
        func fetch(_ tag: ModelTag) -> AsyncStream<Double> {
            AsyncStream { continuation in continuation.finish() }
        }
        func release(_ tag: ModelTag) async {}
    }

    // MARK: - Helpers

    private func makePool() throws -> DatabasePool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SearchModelTests-\(UUID().uuidString)")!
    }

    private func makeModel(search: any VibeSearching,
                           pool: DatabasePool,
                           repository: SmartCrateRepository? = nil,
                           resource: ModelResourceService? = nil,
                           debounceNanoseconds: UInt64 = 250_000_000,
                           defaults: UserDefaults? = nil) -> VibeSearchModel {
        VibeSearchModel(
            searchService: search,
            repository: repository ?? SmartCrateRepository(pool: pool),
            resource: resource ?? ModelResourceService(
                provider: ScriptedProvider(available: [.clapText: true])),
            pool: pool,
            debounceNanoseconds: debounceNanoseconds,
            defaults: defaults ?? makeDefaults())
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool,
                           timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Debounce (§27.5)

    func testSearchIsDebouncedNotImmediate() async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        let search = RecordingSearch()
        let model = makeModel(search: search, pool: pool, debounceNanoseconds: 50_000_000)

        model.updateQuery("dark")
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(search.queries.isEmpty, "no search runs inside the debounce window")

        await waitUntil { model.response != nil }
        XCTAssertEqual(search.queries.map(\.text), ["dark"])
        XCTAssertEqual(model.response?.state, .ready)
    }

    func testRapidTypingCoalescesToOneSearch() async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        let search = RecordingSearch()
        let model = makeModel(search: search, pool: pool, debounceNanoseconds: 50_000_000)

        model.updateQuery("d")
        model.updateQuery("da")
        model.updateQuery("dark")
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(search.queries.isEmpty)

        await waitUntil { model.response != nil }
        XCTAssertEqual(search.queries.map(\.text), ["dark"],
                       "only the final keystroke triggers a search")
    }

    func testInFlightSearchResultIsDiscardedOnNewQuery() async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        let search = GatedSearch()
        let model = makeModel(search: search, pool: pool, debounceNanoseconds: 20_000_000)

        model.updateQuery("aa")   // first search blocks on the gate
        await waitUntil { !search.queries.isEmpty }

        model.updateQuery("b")    // cancels the in-flight "aa" search
        await waitUntil { model.response != nil }

        XCTAssertEqual(search.queries.map(\.text), ["aa", "b"])
        XCTAssertEqual(model.response?.latencyMillis, 1,
                       "the stale 'aa' result (latency 2) never lands — only 'b' publishes")

        search.releaseAll()       // release the blocked continuation so the test exits cleanly
    }

    // MARK: - Coverage (FR-SEM-8)

    func testCoverageReflectsTheServiceCounts() async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        let search = RecordingSearch(coverage: (indexed: 2, total: 5))
        let model = makeModel(search: search, pool: pool)

        await model.refreshCoverage()
        XCTAssertEqual(model.coverage.indexed, 2)
        XCTAssertEqual(model.coverage.total, 5)
    }

    // MARK: - Stated model-absent state (FR-SEM-6)

    func testModelAbsentStateIsStatedAndNeverEmptyPlausible() async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        let search = RecordingSearch()
        search.enqueue(SearchResponse(state: .textModelUnavailable, results: [],
                                      coverage: 0, latencyMillis: 0))
        let provider = ScriptedProvider(available: [:])
        let model = makeModel(search: search, pool: pool,
                              resource: ModelResourceService(provider: provider))

        await model.start()
        XCTAssertFalse(model.textModelAvailable)

        model.updateQuery("dark")
        await waitUntil { model.response != nil }
        XCTAssertEqual(model.response?.state, .textModelUnavailable)
        XCTAssertTrue(model.response?.results.isEmpty ?? false)
    }

    func testFetchTextModelFlippedTheModelAvailableFlag() async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        let provider = ScriptedProvider(available: [:])
        let model = makeModel(search: RecordingSearch(), pool: pool,
                              resource: ModelResourceService(provider: provider))

        await model.start()
        XCTAssertFalse(model.textModelAvailable)

        provider.setAvailable(.clapText, true)
        await model.fetchTextModel()
        XCTAssertTrue(model.textModelAvailable)
    }

    // MARK: - Suggestion chips (library's own distribution)

    func testSuggestionChipsReflectTheLibraryDistribution() async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        for i in 0..<4 {
            seedLibraryTrack(in: pool, title: "Track \(i)",
                             bpm: 124 + Double(i % 2), camelot: "9A",
                             energy: 8, durationSec: 300)
        }
        let model = makeModel(search: RecordingSearch(), pool: pool)
        await model.refreshSuggestions()
        XCTAssertEqual(model.suggestionChips,
                       ["steady around 125 BPM", "in 9A", "high energy"],
                       "chips are seeded from the library's median tempo, dominant key and energy")
    }

    func testEmptyLibraryYieldsNoChips() async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        let model = makeModel(search: RecordingSearch(), pool: pool)
        await model.refreshSuggestions()
        XCTAssertTrue(model.suggestionChips.isEmpty)
    }

    /// Inserts a descriptor-bearing track through the synchronous `write`
    /// overload (GRDB's async overload takes a `@Sendable` closure that cannot
    /// mutate the captured row).
    private func seedLibraryTrack(in pool: DatabasePool, title: String,
                                  bpm: Double? = nil, camelot: String? = nil,
                                  energy: Double? = nil,
                                  durationSec: Double? = nil) {
        var track = DJTrack(syncID: UUID().uuidString, title: title,
                            durationSec: durationSec,
                            contentHash: "h-\(title)", sortKey: "s-\(title)",
                            bpm: bpm, camelot: camelot, energy: energy,
                            addedAt: Date(), updatedAt: Date())
        try? pool.write { db in try track.insert(db) }
    }

    // MARK: - Smart crate save (FR-SEM-5)

    func testSaveAsSmartCratePersistsTheCurrentQuery() async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        let repo = SmartCrateRepository(pool: pool)
        let model = makeModel(search: RecordingSearch(), pool: pool, repository: repo)

        model.queryText = "dark driving bassline"
        model.addPositiveTerm("hypnotic")

        let id = try model.saveAsSmartCrate(name: "Tunnel")
        XCTAssertEqual(model.savedCrate?.id, id)
        let stored = try XCTUnwrap(repo.query(for: id))
        XCTAssertEqual(stored, model.currentQuery)
        XCTAssertEqual(stored.positiveTerms, ["hypnotic"])
    }

    // MARK: - Privacy line (NFR-PRIV-5)

    func testPrivacyLineIsStatedOnceAndRemembered() async throws {
        let pool = try makePool()
        defer { try? pool.close() }
        let defaults = makeDefaults()
        let model = makeModel(search: RecordingSearch(), pool: pool, defaults: defaults)
        XCTAssertFalse(model.privacyAcknowledged, "shown on first use")

        model.acknowledgePrivacy()
        XCTAssertTrue(model.privacyAcknowledged)

        let secondModel = makeModel(search: RecordingSearch(), pool: pool, defaults: defaults)
        XCTAssertTrue(secondModel.privacyAcknowledged,
                      "acknowledgement persists so it is not repeated")
    }
}
