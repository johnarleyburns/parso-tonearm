import XCTest
import GRDB

@testable import TonearmCore
@testable import TonearmDJ
@testable import TonearmDiscovery

/// VibeSearchModel (plan commit 2.5): debounce 250 ms with in-flight cancel
/// (§27.5), honest coverage (FR-SEM-8), stated model-absent state (FR-SEM-6)
/// with an ODR fetch, suggestion chips seeded from the library's own
/// descriptors, smart-crate save (FR-SEM-5), and the one-time privacy line
/// (NFR-PRIV-5).
///
/// C02 (IMPLEMENT_CLAP_PLAN.md, Slice B): rewired off the deleted DJ-local
/// `SemanticSearchService`/`VibeQuery`/`DJTrackRow` stack onto
/// `SearchService`/`DiscoverySearchQuery`/`DiscoverySearchResult` (a core
/// `TrackRow`/`track.id`). The debounce/cancel-mechanics tests below still use
/// a scripted `VibeSearching` fake — they pin TIMING behavior, not track
/// identity, so a fake is legitimate there (unlike the id-space bug session 14
/// flagged); `testSuggestionChipsReflectTheLibraryDistribution` and every
/// other test that touches real track data now seeds REAL core `LibraryStore`
/// tracks, never a DJ-local `DJTrack` fixture.
@MainActor
final class SearchModelTests: XCTestCase {

    // MARK: - Fakes

    /// Records every query and answers from a scripted response queue.
    private final class RecordingSearch: VibeSearching, @unchecked Sendable {
        private let lock = NSLock()
        private var _queries: [DiscoverySearchQuery] = []
        private var _responses: [DiscoverySearchResponse] = []
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

        var queries: [DiscoverySearchQuery] {
            withLock { _queries }
        }

        func setCoverage(_ value: (indexed: Int, total: Int)) {
            withLock { _coverage = value }
        }

        func enqueue(_ response: DiscoverySearchResponse) {
            withLock { _responses.append(response) }
        }

        func search(_ query: DiscoverySearchQuery, referenceTrackID: Int64?,
                    isCancelled: @escaping @Sendable () -> Bool) async -> DiscoverySearchResponse {
            let scripted = withLock { () -> DiscoverySearchResponse? in
                _queries.append(query)
                if !_responses.isEmpty { return _responses.removeFirst() }
                return nil
            }
            if let scripted { return scripted }
            let cov = withLock { _coverage }
            let coverage = SearchRepository.Coverage(
                state: .ready, totalInScope: cov.total, indexed: cov.indexed,
                awaitingIndex: max(0, cov.total - cov.indexed), waitingForAssets: 0,
                failedOrUnsupported: 0, matchingHardFilters: nil)
            return DiscoverySearchResponse(mode: .semantic, state: .ready, results: [],
                                           coverage: coverage, indexGeneration: nil,
                                           latencyMillis: 1)
        }
    }

    /// Blocks the first search on a continuation so tests can observe a stale
    /// in-flight result and prove it is discarded. Latency encodes `text.count`
    /// so responses are distinguishable.
    private final class GatedSearch: VibeSearching, @unchecked Sendable {
        private let lock = NSLock()
        private var _queries: [DiscoverySearchQuery] = []
        private var _pending: [CheckedContinuation<Void, Never>] = []
        private var _blockNext = true

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        var queries: [DiscoverySearchQuery] {
            withLock { _queries }
        }

        func search(_ query: DiscoverySearchQuery, referenceTrackID: Int64?,
                    isCancelled: @escaping @Sendable () -> Bool) async -> DiscoverySearchResponse {
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
            return DiscoverySearchResponse(mode: .semantic, state: .ready, results: [],
                                           coverage: nil, indexGeneration: nil,
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
                           library: LibraryStore? = nil,
                           repository: SmartCrateRepository? = nil,
                           resource: ModelResourceService? = nil,
                           debounceNanoseconds: UInt64 = 250_000_000,
                           defaults: UserDefaults? = nil) throws -> VibeSearchModel {
        VibeSearchModel(
            searchService: search,
            repository: try repository ?? SmartCrateRepository(pool: makePool()),
            resource: resource ?? ModelResourceService(
                provider: ScriptedProvider(available: [.clapText: true])),
            library: try library ?? LibraryStore(inMemory: true),
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

    /// Seeds a real core-imported track (never a DJ-local `DJTrack` — session
    /// 14's own finding) with a `discovery_track_analysis` row so
    /// `SuggestionChips.summary(library:)` finds it.
    private func seedLibraryTrack(in library: LibraryStore, title: String,
                                  bpm: Double? = nil, camelot: String? = nil,
                                  energy: Double? = nil,
                                  durationSec: Double? = nil) async throws {
        let source = try await library.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let track = try await library.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: title, trackNo: nil,
            discNo: nil, durationSec: durationSec, codec: "WAV", sampleRate: 44_100,
            bitDepthOrBitrate: nil, sortKey: title))
        let asset = try await library.insertAsset(Asset(
            id: nil, trackId: track.id!, kind: .localRef, bookmark: nil,
            relPath: "\(title).wav", remoteURL: nil, altRemoteURL: nil,
            sizeBytes: nil, unsupportedReason: nil))
        let writer = await library.dbQueue
        try await writer.write { db in
            var row = DiscoveryTrackAnalysis(
                trackId: track.id!, assetId: asset.id!, assetRevision: 1,
                analysisVersion: DiscoveryPipelineVersion.musicalAnalysis,
                bpm: bpm, key: camelot, energy: energy, phraseSummary: nil,
                analysisScopeSeconds: nil, completedAt: Date())
            try row.upsert(db)
        }
    }

    // MARK: - Debounce (§27.5)

    func testSearchIsDebouncedNotImmediate() async throws {
        let search = RecordingSearch()
        let model = try makeModel(search: search, debounceNanoseconds: 50_000_000)

        model.updateQuery("dark")
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(search.queries.isEmpty, "no search runs inside the debounce window")

        await waitUntil { model.response != nil }
        XCTAssertEqual(search.queries.map(\.text), ["dark"])
        XCTAssertEqual(model.response?.state, .ready)
    }

    func testRapidTypingCoalescesToOneSearch() async throws {
        let search = RecordingSearch()
        let model = try makeModel(search: search, debounceNanoseconds: 50_000_000)

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
        let search = GatedSearch()
        let model = try makeModel(search: search, debounceNanoseconds: 20_000_000)

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
        let search = RecordingSearch(coverage: (indexed: 2, total: 5))
        let model = try makeModel(search: search)

        await model.refreshCoverage()
        XCTAssertEqual(model.coverage.indexed, 2)
        XCTAssertEqual(model.coverage.total, 5)
    }

    // MARK: - Stated model-absent state (FR-SEM-6)

    func testModelAbsentStateIsStatedAndNeverEmptyPlausible() async throws {
        let search = RecordingSearch()
        let provider = ScriptedProvider(available: [:])
        let model = try makeModel(search: search,
                                  resource: ModelResourceService(provider: provider))

        // `start()` itself runs one coverage search — enqueue the scripted
        // model-absent response only AFTER it, so it lands on the real
        // `updateQuery("dark")` search below, not the coverage refresh.
        await model.start()
        XCTAssertFalse(model.textModelAvailable)
        search.enqueue(DiscoverySearchResponse(mode: .semantic, state: .modelMissing, results: [],
                                               coverage: nil, indexGeneration: nil,
                                               latencyMillis: 0))

        model.updateQuery("dark")
        await waitUntil { model.response != nil }
        XCTAssertEqual(model.response?.state, .modelMissing)
        XCTAssertTrue(model.response?.results.isEmpty ?? false)
    }

    func testFetchTextModelFlippedTheModelAvailableFlag() async throws {
        let provider = ScriptedProvider(available: [:])
        let model = try makeModel(search: RecordingSearch(),
                                  resource: ModelResourceService(provider: provider))

        await model.start()
        XCTAssertFalse(model.textModelAvailable)

        provider.setAvailable(.clapText, true)
        await model.fetchTextModel()
        XCTAssertTrue(model.textModelAvailable)
    }

    // MARK: - Suggestion chips (library's own distribution)

    func testSuggestionChipsReflectTheLibraryDistribution() async throws {
        let library = try LibraryStore(inMemory: true)
        for i in 0..<4 {
            try await seedLibraryTrack(in: library, title: "Track \(i)",
                                       bpm: 124 + Double(i % 2), camelot: "9A",
                                       energy: 8, durationSec: 300)
        }
        let model = try makeModel(search: RecordingSearch(), library: library)
        await model.refreshSuggestions()
        XCTAssertEqual(model.suggestionChips,
                       ["steady around 125 BPM", "in 9A", "high energy"],
                       "chips are seeded from the library's median tempo, dominant key and energy")
    }

    func testEmptyLibraryYieldsNoChips() async throws {
        let model = try makeModel(search: RecordingSearch())
        await model.refreshSuggestions()
        XCTAssertTrue(model.suggestionChips.isEmpty)
    }

    // MARK: - Smart crate save (FR-SEM-5)

    func testSaveAsSmartCratePersistsTheCurrentQuery() async throws {
        let pool = try makePool()
        let repo = SmartCrateRepository(pool: pool)
        let model = try makeModel(search: RecordingSearch(), repository: repo)

        model.queryText = "dark driving bassline"
        model.addPositiveTerm("hypnotic")

        let id = try model.saveAsSmartCrate(name: "Tunnel")
        XCTAssertEqual(model.savedCrate?.id, id)
        let stored = try XCTUnwrap(repo.query(for: id))
        XCTAssertEqual(stored, model.currentQuery)
        XCTAssertEqual(stored.positiveRefinements, ["hypnotic"])
    }

    // MARK: - Privacy line (NFR-PRIV-5)

    func testPrivacyLineIsStatedOnceAndRemembered() async throws {
        let defaults = makeDefaults()
        let model = try makeModel(search: RecordingSearch(), defaults: defaults)
        XCTAssertFalse(model.privacyAcknowledged, "shown on first use")

        model.acknowledgePrivacy()
        XCTAssertTrue(model.privacyAcknowledged)

        let secondModel = try makeModel(search: RecordingSearch(), defaults: defaults)
        XCTAssertTrue(secondModel.privacyAcknowledged,
                      "acknowledgement persists so it is not repeated")
    }

    // MARK: - Real core-identity end-to-end (session 14's own standard)

    /// Proves the whole rewired stack agrees on ONE core track id: a real
    /// `SearchService` (not a fake), a real core `LibraryStore`-imported
    /// track, a fixed text encoder for determinism, and `VibeSearchModel`
    /// surfacing the result under `DiscoverySearchResult.trackID` — never a
    /// `DJTrackRow`/DJ-local id anywhere in the path.
    func testRealSearchServiceSurfacesCoreTrackIdentity() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeSearchRealID-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let library = try LibraryStore(inMemory: true)
        let source = try await library.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let track = try await library.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: "One", trackNo: nil,
            discNo: nil, durationSec: 180, codec: "WAV", sampleRate: 44_100,
            bitDepthOrBitrate: nil, sortKey: "One"))
        _ = try await library.insertAsset(Asset(
            id: nil, trackId: track.id!, kind: .localRef, bookmark: nil, relPath: "one.wav",
            remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil))

        let writer = await library.dbQueue
        let index = VectorIndex(writer: writer, cacheURL: dir.appendingPathComponent("vectors.bin"))
        let models = ModelManager(resourceProvider: { .unavailable })
        let service = SearchService(writer: writer, index: index, models: models)

        let model = try makeModel(search: service, library: library)
        model.updateQuery("")
        model.searchImmediately()
        await waitUntil { model.response != nil }

        XCTAssertEqual(model.response?.state, .ready)
        XCTAssertTrue(model.response?.results.contains { $0.trackID == track.id! } ?? false,
                      "the real SearchService must surface the imported track under its core id")
    }
}
