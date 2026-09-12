import XCTest
import GRDB
import ParsoAudioAnalysis

@testable import TonearmCore
@testable import TonearmDJ
@testable import TonearmDiscovery

/// Smart crates (§14, FR-SEM-5): `DiscoverySearchQuery` round-trips through
/// `smart_crate.queryJSON` byte-exact (NFR-DET-3), save/load carries the
/// normalized `crate_rule` rows, delete cascades, and a crate re-evaluates live
/// against the current unified index.
///
/// C02 (IMPLEMENT_CLAP_PLAN.md, Slice B): rewired off the deleted DJ-local
/// `VibeQuery`/`SemanticSearchService`/`VectorStoreTierA` stack onto
/// `DiscoverySearchQuery`/`SearchService`. `testEvaluateReRunsTheStoredQuery`
/// now seeds REAL core `LibraryStore` tracks (not DJ-local `DJTrack` fixtures)
/// — the id space `SearchService` actually resolves against, per session 14's
/// explicit finding that DJ-local test fixtures hid a real core/DJ-local id
/// bug before.
final class SmartCrateTests: XCTestCase {

    // MARK: - Helpers (smart_crate/crate_rule remain DJ-local, see repository doc)

    private func makePool() throws -> DatabasePool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartCrateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
    }

    // MARK: - Byte-exact round trip (NFR-DET-3)

    func testQueryRoundTripsByteExact() throws {
        let query = DiscoverySearchQuery(text: "dark driving bassline",
                              positiveRefinements: ["hypnotic"],
                              negativeRefinements: ["vocals"],
                              bpmMin: 118, bpmMax: 132,
                              compatibleKey: "9A",
                              limit: 50)
        let encoded = try query.encodedJSONString()
        let decoded = try DiscoverySearchQuery.decodeJSON(encoded)
        XCTAssertEqual(decoded, query)
        XCTAssertEqual(try decoded.encodedJSONString(), encoded,
                       "encode → decode → encode must be byte-identical")
    }

    func testEmptyQueryRoundTrips() throws {
        let query = DiscoverySearchQuery(text: "")
        let encoded = try query.encodedJSONString()
        XCTAssertEqual(try DiscoverySearchQuery.decodeJSON(encoded), query)
    }

    // MARK: - Save / load / normalized rules

    func testSaveLoadCrateRoundTripAndNormalizedRules() throws {
        let pool = try makePool()
        let repo = SmartCrateRepository(pool: pool)
        let query = DiscoverySearchQuery(text: "dark bassline",
                              positiveRefinements: ["hypnotic"],
                              bpmMin: 120, bpmMax: 128,
                              compatibleKey: "8A")

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
        let id = try repo.save(query: DiscoverySearchQuery(text: "hypnotic"), name: "Vibe only")
        XCTAssertTrue(try repo.rules(for: id).isEmpty,
                      "a purely-semantic crate has no relational rules; queryJSON is truth")
    }

    func testDeleteCascadesRules() throws {
        let pool = try makePool()
        let repo = SmartCrateRepository(pool: pool)
        let id = try repo.save(query: DiscoverySearchQuery(text: "dark", bpmMin: 118, bpmMax: 130),
                               name: "Temporary")
        XCTAssertEqual(try repo.rules(for: id).count, 1)
        try repo.delete(id: id)
        XCTAssertNil(try repo.crate(id: id))
        XCTAssertTrue(try repo.rules(for: id).isEmpty,
                      "crate_rule rows cascade on delete (§14.3)")
    }

    func testEvaluateThrowsForMissingCrate() async throws {
        let pool = try makePool()
        let repo = SmartCrateRepository(pool: pool)
        let writer = try DatabaseQueue()
        try Schema.migrator().migrate(writer)
        let service = SearchService(writer: writer,
                                    index: VectorIndex(writer: writer,
                                                        cacheURL: FileManager.default.temporaryDirectory
                                                            .appendingPathComponent("v-\(UUID().uuidString).bin")),
                                    models: ModelManager(resourceProvider: { .unavailable }))
        await assertThrowsErrorAsync {
            _ = try await repo.evaluate(id: 9_999, using: service)
        }
    }

    // MARK: - Live re-evaluation (FR-SEM-5), against a REAL core-seeded track

    func testEvaluateReRunsTheStoredQuery() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartCrateEval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        defer { try? pool.close() }

        // The core library — SmartCrateRepository's evaluate() now runs
        // against this, not a DJ-local `DJTrack` fixture.
        let core = try LibraryStore(inMemory: true)
        let source = try await core.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let darkTrack = try await core.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: "Dark", trackNo: nil,
            discNo: nil, durationSec: 200, codec: "WAV", sampleRate: 44_100,
            bitDepthOrBitrate: nil, sortKey: "Dark"))
        let brightTrack = try await core.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: "Bright", trackNo: nil,
            discNo: nil, durationSec: 200, codec: "WAV", sampleRate: 44_100,
            bitDepthOrBitrate: nil, sortKey: "Bright"))
        let darkAsset = try await core.insertAsset(Asset(
            id: nil, trackId: darkTrack.id!, kind: .localRef, bookmark: nil, relPath: "dark.wav",
            remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil))
        let brightAsset = try await core.insertAsset(Asset(
            id: nil, trackId: brightTrack.id!, kind: .localRef, bookmark: nil, relPath: "bright.wav",
            remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil))

        let dims = 8
        let darkVector: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let brightVector: [Float] = [0, 1, 0, 0, 0, 0, 0, 0]
        let writer = await core.dbQueue
        try await writer.write { db in
            for (trackID, assetID, vector) in [(darkTrack.id!, darkAsset.id!, darkVector),
                                                (brightTrack.id!, brightAsset.id!, brightVector)] {
                let unit = SemanticPooling.l2Normalized(vector)
                let (int8, scale) = VectorQuantization.quantize(unit)
                var row = DiscoveryEmbedding(
                    trackId: trackID, assetId: assetID, assetRevision: 1,
                    modelVersion: DiscoveryPipelineVersion.model,
                    preprocessingVersion: DiscoveryPipelineVersion.preprocessing,
                    samplingVersion: DiscoveryPipelineVersion.sampling,
                    dimensions: unit.count, quantizedVector: VectorQuantization.data(int8),
                    scale: Double(scale), completedAt: Date())
                try row.upsert(db)
            }
        }

        let models = ModelManager(resourceProvider: { .unavailable })
        await models.injectModelForTesting(FixedTextModel(dimensions: dims, vector: darkVector))
        let cacheURL = dir.appendingPathComponent("vectors.bin")
        let service = SearchService(writer: writer, index: VectorIndex(writer: writer, cacheURL: cacheURL),
                                    models: models)

        let repo = SmartCrateRepository(pool: pool)
        let id = try repo.save(query: DiscoverySearchQuery(text: "dark driving bassline"),
                               name: "Dark tunnel")
        let response = try await repo.evaluate(id: id, using: service)
        XCTAssertEqual(response.state, .ready)
        XCTAssertEqual(response.results.first?.trackID, darkTrack.id!,
                       "crate re-evaluates live against the core index and ranks the match first")
        XCTAssertEqual(response.results.map(\.trackID).count, 2)
    }

    private func assertThrowsErrorAsync(_ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected an error to be thrown")
        } catch {
            // expected
        }
    }
}

/// A `SemanticModel` that returns one fixed vector for any text — lets a test
/// drive `SearchService`'s semantic path with an exact query vector, without
/// needing a real CoreML CLAP text encoder on this host.
private struct FixedTextModel: SemanticModel {
    let spec: EmbeddingModelSpec
    let vector: [Float]

    init(dimensions: Int, vector: [Float]) {
        var spec = EmbeddingModelSpec.musicCLAPMetadata
        spec.dimensions = dimensions
        self.spec = spec
        self.vector = SemanticPooling.l2Normalized(vector)
    }

    func embedText(_ text: String) async throws -> [Float] { vector }
    func embedAudio(logMel: [Float]) async throws -> [Float] { vector }
}
