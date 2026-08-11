import XCTest
import GRDB
import TonearmCore

@testable import TonearmDJ

/// EmbeddingCoordinator lane (§5 2.2): stale-only reconcile, FR-SEM-6 availability
/// gate, single-transaction persist, governor lane + performance pin (FR-ANL-2).
final class EmbeddingCoordinatorTests: XCTestCase {

    /// Scripted ODR availability, deterministic for macOS `swift test`.
    private final class ScriptedProvider: ModelResourceProviding, @unchecked Sendable {        let tagFileNames: [ModelTag: String] = [:]
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

    /// Thread-safe accumulator for the `@Sendable` index-change hook.
    private final class CollectBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [[Int64]] = []
        var values: [[Int64]] {
            lock.lock(); defer { lock.unlock() }
            return _values
        }
        func append(_ value: [Int64]) {
            lock.lock(); defer { lock.unlock() }
            _values.append(value)
        }
    }

    // MARK: - Helpers

    private func makePool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddingCoordTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("tonearm-dj.sqlite")
        let pool = try DJDatabase.open(at: dbURL)
        return (pool, dir.appendingPathComponent("vectors.i8"))
    }

    private func makeToneWAV(at url: URL, seconds: Double = 1.0) throws {
        var sampleRate: UInt32 = 48_000
        let frames = Int(seconds * 48_000)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        var size = UInt32(36 + frames * 2)
        data.append(Data(bytes: &size, count: 4))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        var fmtSize = UInt32(16); data.append(Data(bytes: &fmtSize, count: 4))
        var pcm: UInt16 = 1; data.append(Data(bytes: &pcm, count: 2))
        var mono: UInt16 = 1; data.append(Data(bytes: &mono, count: 2))
        data.append(Data(bytes: &sampleRate, count: 4))
        var byteRate = sampleRate * 2; data.append(Data(bytes: &byteRate, count: 4))
        var align: UInt16 = 2; data.append(Data(bytes: &align, count: 2))
        var bits: UInt16 = 16; data.append(Data(bytes: &bits, count: 2))
        data.append(contentsOf: Array("data".utf8))
        var dataSize = UInt32(frames * 2); data.append(Data(bytes: &dataSize, count: 4))
        for i in 0..<frames {
            let sample = Int16((Float(sin(2 * Double.pi * 440 * Double(i) / 48_000)) * 0.5
                                * Float(Int16.max)).rounded())
            var le = sample.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        try data.write(to: url)
    }

    @discardableResult
    private func seedTrack(in pool: DatabasePool, title: String, url: URL) throws -> Int64 {
        var track = DJTrack(syncID: UUID().uuidString, title: title,
                            contentHash: "hash-\(title)", sortKey: title,
                            addedAt: Date(), updatedAt: Date())
        try pool.write { db in try track.insert(db) }
        guard let id = track.id else { return 0 }
        var asset = DJAsset(trackID: id,
                            bookmark: BookmarkVault.makeBookmark(for: url),
                            relPath: url.lastPathComponent)
        try pool.write { db in try asset.insert(db) }
        return id
    }

    /// A tiny but structurally-valid spec: 32-D, 0.5 s windows at 48 kHz, a
    /// unit filterbank. Preprocess + pooling run for real; only the encoder is fake.
    private func makeSpec() -> EmbeddingModelSpec {
        let fftSize = 256
        let melBins = 8
        let bins = fftSize / 2 + 1
        return EmbeddingModelSpec(modelName: "coordinator-test",
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

    private func makeCoordinator(pool: DatabasePool,
                                 store: any VectorStore,
                                 provider: ScriptedProvider,
                                 governorGate: @escaping @Sendable () -> Bool = { true },
                                 onIndexChange: @escaping @Sendable ([Int64]) -> Void = { _ in })
        -> EmbeddingCoordinator {
        let embedder = CLAPEmbedder(model: DeterministicFakeSemanticModel(spec: makeSpec()))
        return EmbeddingCoordinator(pool: pool, embedder: embedder, store: store,
                                    resource: ModelResourceService(provider: provider),
                                    governorAllowsRun: governorGate,
                                    onIndexChange: onIndexChange)
    }

    private func storeState(_ pool: DatabasePool, trackID: Int64) throws -> Int? {
        try pool.read { db in
            try DJTrackEmbedding.filter(Column("trackID") == trackID).fetchOne(db)?.matrixRow
        }
    }

    private func embeddingVersion(_ pool: DatabasePool, trackID: Int64) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT embeddingVersion FROM track WHERE id = ?",
                             arguments: [trackID]) ?? 0
        }
    }

    // MARK: - Availability gate (FR-SEM-6)

    func testAvailabilityGateHaltsReconcileAndLane() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: 32, fileURL: matrixURL)
        let provider = ScriptedProvider(available: [:])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emb-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
        try makeToneWAV(at: url)
        _ = try seedTrack(in: pool, title: "a", url: url)

        let coordinator = makeCoordinator(pool: pool, store: store, provider: provider)
        let stale = try await coordinator.reconcileEmbeddings()
        XCTAssertEqual(stale, 0, "no audio model -> no embeddings, honestly (never a lie)")

        await coordinator.runEmbeddingLane()
        XCTAssertEqual(store.rowCount, 0)
        let firstTrack = try await pool.read { try DJTrack.fetchAll($0).compactMap(\.id).first }
        if let firstTrack {
            XCTAssertNil(try storeState(pool, trackID: firstTrack))
        } else {
            XCTFail("no track seeded")
        }
    }

    // MARK: - Reconcile

    func testReconcileEnqueuesOnlyStaleTracks() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: 32, fileURL: matrixURL)
        let provider = ScriptedProvider(available: [.clapAudio: true])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emb-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
        try makeToneWAV(at: url)
        _ = try seedTrack(in: pool, title: "a", url: url)
        _ = try seedTrack(in: pool, title: "b", url: url)
        let c = try seedTrack(in: pool, title: "c", url: url)
        try await pool.write { db in
            try db.execute(sql: "UPDATE track SET embeddingVersion = 1 WHERE id = ?", arguments: [c])
        }

        let coordinator = makeCoordinator(pool: pool, store: store, provider: provider)
        let stale = try await coordinator.reconcileEmbeddings()
        XCTAssertEqual(stale, 2, "only tracks with embeddingVersion < 1 are enqueued")
    }

    // MARK: - Lane persist

    func testLanePersistsEmbeddingAndVersionInOneTransaction() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: 32, fileURL: matrixURL)
        let provider = ScriptedProvider(available: [.clapAudio: true])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emb-lane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
        try makeToneWAV(at: url)
        let a = try seedTrack(in: pool, title: "a", url: url)
        let b = try seedTrack(in: pool, title: "b", url: url)

        let coordinator = makeCoordinator(pool: pool, store: store, provider: provider)
        await coordinator.runEmbeddingLane()

        XCTAssertEqual(try embeddingVersion(pool, trackID: a), 1)
        XCTAssertEqual(try embeddingVersion(pool, trackID: b), 1)
        XCTAssertNotNil(try storeState(pool, trackID: a), "track_embedding row written")
        XCTAssertNotNil(try storeState(pool, trackID: b))
        XCTAssertEqual(store.rowCount, 2, "matrix appended in the same transaction")
        XCTAssertEqual(store.tombstoneCount, 0)

        // The pooled vector is searchable.
        let matrixRow = try XCTUnwrap(storeState(pool, trackID: a))
        let results = try store.search(query: unitVector(phase: 1.0), topK: 2,
                                       isCancelled: { false })
        XCTAssertEqual(results.count, 2)
        _ = matrixRow
    }

    // MARK: - Governor + performance gates

    func testGovernorGateHaltsLane() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: 32, fileURL: matrixURL)
        let provider = ScriptedProvider(available: [.clapAudio: true])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emb-gov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
        try makeToneWAV(at: url)
        let a = try seedTrack(in: pool, title: "a", url: url)

        // `.embeddings` lane shed → nothing runs (§43.7).
        let coordinator = makeCoordinator(pool: pool, store: store, provider: provider,
                                          governorGate: { false })
        await coordinator.runEmbeddingLane()
        XCTAssertEqual(try embeddingVersion(pool, trackID: a), 0)
        XCTAssertEqual(store.rowCount, 0)
    }

    func testPerformancePinsLanePaused() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: 32, fileURL: matrixURL)
        let provider = ScriptedProvider(available: [.clapAudio: true])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emb-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
        try makeToneWAV(at: url)
        let a = try seedTrack(in: pool, title: "a", url: url)

        let coordinator = makeCoordinator(pool: pool, store: store, provider: provider)
        await coordinator.setPerforming(true)
        await coordinator.runEmbeddingLane()
        XCTAssertEqual(try embeddingVersion(pool, trackID: a), 0, "FR-ANL-2: paused during a performance")
        XCTAssertEqual(store.rowCount, 0)
    }

    // MARK: - Index-change hook

    func testIndexChangeHookFiresPerTrack() async throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: 32, fileURL: matrixURL)
        let provider = ScriptedProvider(available: [.clapAudio: true])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emb-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
        try makeToneWAV(at: url)
        let a = try seedTrack(in: pool, title: "a", url: url)
        let b = try seedTrack(in: pool, title: "b", url: url)

        let box = CollectBox()
        let coordinator = makeCoordinator(pool: pool, store: store, provider: provider,
                                          onIndexChange: { box.append($0) })
        await coordinator.runEmbeddingLane()
        XCTAssertEqual(box.values.count, 2)
        XCTAssertEqual(box.values.flatMap { $0 }, [a, b])
    }

    private func unitVector(phase: Double, dims: Int = 32) -> [Float] {
        let raw = (0..<dims).map { Float(sin(phase + Double($0) * 0.23)) }
        let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        return raw.map { $0 / norm }
    }
}
