import XCTest
import GRDB

@testable import TonearmDJ

/// SemanticSearchService façade (§27.5, §16.5): fake-embedder end-to-end for the
/// text path, audio-to-audio self-exclusion (FR-SEM-7), +/− refinement (FR-SEM-4),
/// honest coverage (FR-SEM-8), and stated absence states (FR-SEM-6).
final class SemanticSearchServiceTests: XCTestCase {

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

    private let storeDims = 32

    // MARK: - Helpers

    private func makePool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemanticSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("tonearm-dj.sqlite")
        let pool = try DJDatabase.open(at: dbURL)
        return (pool, dir.appendingPathComponent("vectors.i8"))
    }

    private func makeSpec() -> EmbeddingModelSpec {
        let fftSize = 256
        let melBins = 8
        let bins = fftSize / 2 + 1
        return EmbeddingModelSpec(modelName: "search-test",
                                  dimensions: storeDims,
                                  sampleRate: 48_000,
                                  windowSeconds: 0.5,
                                  hopSeconds: 0.25,
                                  fftSize: fftSize,
                                  hopSize: 120,
                                  melBins: melBins,
                                  lowHz: 50,
                                  highHz: 14_000,
                                  clipSamples: 24_000,
                                  frames: 201,
                                  maxWindows: 240,
                                  textMaxLength: 77,
                                  pooling: .attention,
                                  melFilterBank: [Float](repeating: 1, count: bins * melBins))
    }

    private func makeEmbedder() -> CLAPEmbedder {
        CLAPEmbedder(model: DeterministicFakeSemanticModel(spec: makeSpec()))
    }

    private func makeService(pool: DatabasePool, store: any VectorStore,
                             provider: ScriptedProvider, embedder: CLAPEmbedder? = nil)
        -> SemanticSearchService {
        SemanticSearchService(pool: pool, store: store,
                              embedder: embedder ?? makeEmbedder(),
                              resource: ModelResourceService(provider: provider))
    }

    @discardableResult
    private func seedTrack(in pool: DatabasePool, title: String,
                           bpm: Double? = nil, camelot: String? = nil,
                           energy: Double? = nil) throws -> Int64 {
        var track = DJTrack(syncID: UUID().uuidString, title: title,
                            contentHash: "hash-\(title)", sortKey: title,
                            bpm: bpm, camelot: camelot, energy: energy,
                            addedAt: Date(), updatedAt: Date())
        try pool.write { db in try track.insert(db) }
        return try XCTUnwrap(track.id)
    }

    /// Upsert an embedding whose vector is the fake embedder's text embedding of
    /// `text` — so a matching query ranks it first (deterministic, no weights).
    private func storeTextVector(_ text: String, trackID: Int64,
                                 pool: DatabasePool, store: any VectorStore,
                                 embedder: CLAPEmbedder) async throws {
        let vector = try await embedder.embedText(text)
        let (int8, scale) = VectorQuantization.quantize(vector)
        try await pool.write { db in
            try store.upsert(DJTrackEmbedding(trackID: trackID, int8Vector: int8,
                                              scale: Double(scale), matrixRow: nil,
                                              version: 1),
                             db: db)
        }
    }

    private func topIDs(_ response: SearchResponse) -> [Int64] {
        response.results.map(\.track.id)
    }

    // MARK: - Text query ranks stored tracks (FR-SEM-1/2)

    func testTextQueryRanksStoredTracks() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let embedder = makeEmbedder()
        let a = try seedTrack(in: pool, title: "Alpha")
        let b = try seedTrack(in: pool, title: "Beta")
        try await storeTextVector("dark driving bassline", trackID: a,
                                  pool: pool, store: store, embedder: embedder)
        try await storeTextVector("bright sunshine pop", trackID: b,
                                  pool: pool, store: store, embedder: embedder)

        let provider = ScriptedProvider(available: [.clapText: true])
        let service = makeService(pool: pool, store: store, provider: provider,
                                  embedder: embedder)
        let response = try await service.search(VibeQuery(text: "dark driving bassline"))
        XCTAssertEqual(response.state, .ready)
        XCTAssertEqual(topIDs(response).first, a)
        XCTAssertTrue(response.results.first?.similarity ?? 0 > 0.9,
                      "matching text embedding ranks ~1.0")
    }

    // MARK: - Audio-to-audio self-exclusion (FR-SEM-7)

    func testSimilarToExcludesReferenceItself() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let embedder = makeEmbedder()
        let a = try seedTrack(in: pool, title: "Alpha")
        let b = try seedTrack(in: pool, title: "Beta")
        let c = try seedTrack(in: pool, title: "Gamma")
        try await storeTextVector("dark driving bassline", trackID: a,
                                  pool: pool, store: store, embedder: embedder)
        try await storeTextVector("dark driving bassline", trackID: b,
                                  pool: pool, store: store, embedder: embedder)
        try await storeTextVector("bright sunshine pop", trackID: c,
                                  pool: pool, store: store, embedder: embedder)

        let provider = ScriptedProvider(available: [.clapText: true])
        let service = makeService(pool: pool, store: store, provider: provider,
                                  embedder: embedder)
        let response = try await service.similar(to: a)
        XCTAssertEqual(response.state, .ready)
        XCTAssertFalse(topIDs(response).contains(a), "reference track excluded itself")
        XCTAssertEqual(topIDs(response).first, b, "audio-most-similar other track ranks first")
    }

    func testSimilarToUnindexedReferenceReturnsStatedState() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let provider = ScriptedProvider(available: [.clapText: true])
        let service = makeService(pool: pool, store: store, provider: provider)
        let orphan = try seedTrack(in: pool, title: "No Embedding")
        let response = try await service.similar(to: orphan)
        XCTAssertEqual(response.state, .unindexedReference)
        XCTAssertTrue(response.results.isEmpty)
    }

    // MARK: - +/− refinement (FR-SEM-4)

    func testPositiveAndNegativeTermsShiftResultsDeterministically() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let embedder = makeEmbedder()
        let dark = try seedTrack(in: pool, title: "Dark")
        let hypnotic = try seedTrack(in: pool, title: "Hypnotic")
        let cheesy = try seedTrack(in: pool, title: "Cheesy")
        try await storeTextVector("dark", trackID: dark,
                                  pool: pool, store: store, embedder: embedder)
        try await storeTextVector("hypnotic", trackID: hypnotic,
                                  pool: pool, store: store, embedder: embedder)
        try await storeTextVector("cheesy", trackID: cheesy,
                                  pool: pool, store: store, embedder: embedder)

        let provider = ScriptedProvider(available: [.clapText: true])
        let service = makeService(pool: pool, store: store, provider: provider,
                                  embedder: embedder)

        // Base query: dark dominates.
        let base = try await service.search(VibeQuery(text: "dark"))
        XCTAssertEqual(topIDs(base).first, dark)

        // +hypnotic −cheesy pulls the query anchor away from both.
        let refined = try await service.search(VibeQuery(text: "dark",
                                                         positiveTerms: ["hypnotic"],
                                                         negativeTerms: ["cheesy"]))
        XCTAssertEqual(topIDs(refined).first, hypnotic,
                       "positive term re-anchors the query toward it (FR-SEM-4)")

        // Determinism: the same refined query twice returns identical ordering.
        let again = try await service.search(VibeQuery(text: "dark",
                                                       positiveTerms: ["hypnotic"],
                                                       negativeTerms: ["cheesy"]))
        XCTAssertEqual(topIDs(refined), topIDs(again))
    }

    // MARK: - Coverage honesty (FR-SEM-8)

    func testCoverageIsHonestWithPartialIndex() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let embedder = makeEmbedder()
        let a = try seedTrack(in: pool, title: "Alpha")
        let b = try seedTrack(in: pool, title: "Beta")
        let c = try seedTrack(in: pool, title: "Gamma")
        let d = try seedTrack(in: pool, title: "Delta")
        let e = try seedTrack(in: pool, title: "Echo")
        // Only two of five are indexed.
        try await storeTextVector("dark", trackID: a, pool: pool, store: store, embedder: embedder)
        try await storeTextVector("dark", trackID: b, pool: pool, store: store, embedder: embedder)
        _ = c; _ = d; _ = e

        let provider = ScriptedProvider(available: [.clapText: true])
        let service = makeService(pool: pool, store: store, provider: provider,
                                  embedder: embedder)
        let fraction = await service.coverageFraction()
        XCTAssertEqual(fraction, 0.4, accuracy: 1e-9,
                       "2 indexed ÷ 5 total — honest, not assumed 1.0")

        let response = try await service.search(VibeQuery(text: "dark"))
        XCTAssertEqual(response.coverage, 0.4, accuracy: 1e-9)
        XCTAssertEqual(topIDs(response), [a, b], "results come only from what is indexed")
    }

    func testIndexDidChangeWarmsCoverageCache() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let embedder = makeEmbedder()
        let a = try seedTrack(in: pool, title: "Alpha")
        let b = try seedTrack(in: pool, title: "Beta")

        let provider = ScriptedProvider(available: [.clapText: true])
        let service = makeService(pool: pool, store: store, provider: provider,
                                  embedder: embedder)
        let empty = await service.coverageFraction()
        XCTAssertEqual(empty, 0.0, accuracy: 1e-9)

        try await storeTextVector("dark", trackID: a, pool: pool, store: store, embedder: embedder)
        await service.indexDidChange(trackIDs: [a])
        let half = await service.coverageFraction()
        XCTAssertEqual(half, 0.5, accuracy: 1e-9,
                       "indexDidChange refreshes the coverage cache")

        try await storeTextVector("dark", trackID: b, pool: pool, store: store, embedder: embedder)
        await service.indexDidChange(trackIDs: [b])
        let full = await service.coverageFraction()
        XCTAssertEqual(full, 1.0, accuracy: 1e-9)
    }

    // MARK: - Stated absence (FR-SEM-6)

    func testEmptyQueryReturnsStatedState() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let provider = ScriptedProvider(available: [.clapText: true])
        let service = makeService(pool: pool, store: store, provider: provider)
        let response = try await service.search(VibeQuery(text: "   "))
        XCTAssertEqual(response.state, .emptyQuery)
        XCTAssertTrue(response.results.isEmpty)
    }

    func testAbsentTextModelReturnsStatedStateNeverEmptyPlausible() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let embedder = makeEmbedder()
        let a = try seedTrack(in: pool, title: "Alpha")
        try await storeTextVector("dark", trackID: a, pool: pool, store: store, embedder: embedder)

        // Text tag absent → honest model-unavailable state, not fake "no results".
        let provider = ScriptedProvider(available: [:])
        let service = makeService(pool: pool, store: store, provider: provider,
                                  embedder: embedder)
        let response = try await service.search(VibeQuery(text: "dark"))
        XCTAssertEqual(response.state, .textModelUnavailable)
        XCTAssertTrue(response.results.isEmpty)

        // Audio-to-audio still works — it never needs the text encoder.
        let similar = try await service.similar(to: a)
        XCTAssertEqual(similar.state, .ready)
    }
}
