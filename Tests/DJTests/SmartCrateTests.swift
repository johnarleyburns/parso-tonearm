import XCTest
import GRDB

@testable import TonearmDJ

/// Smart crates (§14, FR-SEM-5): `VibeQuery` round-trips through
/// `smart_crate.queryJSON` byte-exact (NFR-DET-3), save/load carries the
/// normalized `crate_rule` rows, delete cascades, and a crate re-evaluates live
/// against the current index.
final class SmartCrateTests: XCTestCase {

    // MARK: - Helpers

    private func makePool() throws -> DatabasePool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartCrateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
    }

    private func makeSpec() -> EmbeddingModelSpec {
        let fftSize = 256
        let melBins = 8
        let bins = fftSize / 2 + 1
        return EmbeddingModelSpec(modelName: "crate-test",
                                  dimensions: 32,
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

    // MARK: - Byte-exact round trip (NFR-DET-3)

    func testQueryRoundTripsByteExact() throws {
        let query = VibeQuery(text: "dark driving bassline",
                              positiveTerms: ["hypnotic"],
                              negativeTerms: ["vocals"],
                              bpmRange: 118...132,
                              compatibleWithKey: CamelotKey(code: "9A"),
                              limit: 50)
        let encoded = try query.encodedJSONString()
        let decoded = try VibeQuery.decodeJSON(encoded)
        XCTAssertEqual(decoded, query)
        XCTAssertEqual(try decoded.encodedJSONString(), encoded,
                       "encode → decode → encode must be byte-identical")
    }

    func testEmptyQueryRoundTrips() throws {
        let query = VibeQuery(text: "")
        let encoded = try query.encodedJSONString()
        XCTAssertEqual(try VibeQuery.decodeJSON(encoded), query)
    }

    // MARK: - Save / load / normalized rules

    func testSaveLoadCrateRoundTripAndNormalizedRules() throws {
        let pool = try makePool()
        let repo = SmartCrateRepository(pool: pool)
        let query = VibeQuery(text: "dark bassline",
                              positiveTerms: ["hypnotic"],
                              bpmRange: 120...128,
                              compatibleWithKey: CamelotKey(code: "8A"))

        let id = try repo.save(query: query, name: "Tunnel music")
        let crate = try XCTUnwrap(repo.crate(id: id))
        XCTAssertEqual(crate.name, "Tunnel music")
        XCTAssertFalse(crate.pinned)
        XCTAssertEqual(try repo.query(for: id), query,
                       "stored query decodes equal to the saved one")

        let rules = try repo.rules(for: id)
        XCTAssertEqual(rules.count, 2, "bpm + camelot normalize to crate_rule rows")
        XCTAssertTrue(rules.contains { $0.field == "bpm" && $0.op == "between" },
                      "BPM range is a readable 'between' rule")
        XCTAssertTrue(rules.contains { $0.field == "camelot" && $0.op == "in" },
                      "Camelot compatibility is a readable 'in' rule")

        XCTAssertEqual(try repo.crates().count, 1)
    }

    func testPurelySemanticQuerySavesWithNoRules() throws {
        let pool = try makePool()
        let repo = SmartCrateRepository(pool: pool)
        let id = try repo.save(query: VibeQuery(text: "hypnotic"), name: "Vibe only")
        XCTAssertTrue(try repo.rules(for: id).isEmpty,
                      "a purely-semantic crate has no relational rules; queryJSON is truth")
    }

    func testDeleteCascadesRules() throws {
        let pool = try makePool()
        let repo = SmartCrateRepository(pool: pool)
        let id = try repo.save(query: VibeQuery(text: "dark", bpmRange: 118...130),
                               name: "Temporary")
        XCTAssertEqual(try repo.rules(for: id).count, 1)
        try repo.delete(id: id)
        XCTAssertNil(try repo.crate(id: id))
        XCTAssertTrue(try repo.rules(for: id).isEmpty,
                      "crate_rule rows cascade on delete (§14.3)")
    }

    // MARK: - Live re-evaluation (FR-SEM-5)

    func testEvaluateReRunsTheStoredQuery() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartCrateEval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: 32,
                                         fileURL: dir.appendingPathComponent("vectors.i8"))
        let embedder = CLAPEmbedder(model: DeterministicFakeSemanticModel(spec: makeSpec()))
        let provider = ScriptedProvider(available: [.clapText: true])
        let service = SemanticSearchService(pool: pool, store: store, embedder: embedder,
                                            resource: ModelResourceService(provider: provider))

        let darkID = try seedTrack(in: pool, title: "Dark")
        let brightID = try seedTrack(in: pool, title: "Bright")
        try await storeTextVector("dark driving bassline", trackID: darkID,
                                  pool: pool, store: store, embedder: embedder)
        try await storeTextVector("bright sunshine pop", trackID: brightID,
                                  pool: pool, store: store, embedder: embedder)

        let repo = SmartCrateRepository(pool: pool)
        let id = try repo.save(query: VibeQuery(text: "dark driving bassline"),
                               name: "Dark tunnel")
        let response = try await repo.evaluate(id: id, using: service)
        XCTAssertEqual(response.state, .ready)
        XCTAssertEqual(response.results.first?.track.id, darkID,
                       "crate re-evaluates live and ranks the match first")
        XCTAssertEqual(response.results.map(\.track.id).count, 2)
    }

    // MARK: - Local helpers

    /// Inserts a track through the synchronous `write` overload (GRDB's async
    /// overload takes a `@Sendable` closure that cannot mutate the captured row).
    private func seedTrack(in pool: DatabasePool, title: String) throws -> Int64 {
        var track = DJTrack(syncID: UUID().uuidString, title: title,
                            contentHash: "hash-\(title)", sortKey: title,
                            addedAt: Date(), updatedAt: Date())
        try pool.write { db in try track.insert(db) }
        return try XCTUnwrap(track.id)
    }

    private func storeTextVector(_ text: String, trackID: Int64,
                                 pool: DatabasePool, store: any VectorStore,
                                 embedder: CLAPEmbedder) async throws {
        let vector = try await embedder.embedText(text)
        let (int8, scale) = VectorQuantization.quantize(vector)
        try await pool.write { db in
            try store.upsert(DJTrackEmbedding(trackID: trackID, int8Vector: int8,
                                              scale: Double(scale), matrixRow: nil,
                                              version: 1), db: db)
        }
    }

    /// Scripted ODR availability, deterministic for macOS `swift test`.
    private final class ScriptedProvider: ModelResourceProviding, @unchecked Sendable {
        let tagFileNames: [ModelTag: String] = [:]
        private let lock = NSLock()
        private var _available: [ModelTag: Bool]

        init(available: [ModelTag: Bool]) { _available = available }

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
}
