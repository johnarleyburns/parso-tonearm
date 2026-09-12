#if !os(watchOS)
import Foundation
import GRDB
import ParsoAudioNeural
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// Plan §9/§11 C06: a 20,000-track scope must scan without hitting SQLite's
/// bound-variable limit, without an ANN dependency and without a full-matrix
/// copy per query.
final class SearchServiceScaleTests: XCTestCase {
    func testTwentyThousandTrackScopeScansWithoutSQLVariableError() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scale-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let dims = 8
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            for i in 0..<20_000 {
                let t = try SearchFixture.seedTrack(db, sourceId: s, title: "t\(i)", sortKey: String(format: "%06d", i))
                let a = try SearchFixture.seedAsset(db, trackId: t)
                // A cheap deterministic spread of vectors.
                let x = Float((i % 7) + 1)
                let y = Float((i % 5) + 1)
                try SearchFixture.seedEmbedding(
                    db, trackId: t, assetId: a, vector: [x, y, 0, 0, 0, 0, 0, 0])
                if i % 3 == 0 {
                    try SearchFixture.seedAnalysis(db, trackId: t, assetId: a, bpm: 120 + Double(i % 20))
                }
            }
        }

        let models = ModelManager(resourceProvider: { .unavailable })
        await models.injectModelForTesting(
            FixedTextModel(dimensions: dims, vector: [1, 0, 0, 0, 0, 0, 0, 0]))
        let service = SearchService(
            writer: queue, index: VectorIndex(writer: queue, cacheURL: cacheURL), models: models)

        // Whole-library semantic scan.
        let all = await service.search(DiscoverySearchQuery(text: "x", limit: 50))
        XCTAssertEqual(all.state, .ready)
        XCTAssertEqual(all.results.count, 50)

        // Semantic + hard BPM gate over the same 20k scope.
        let filtered = await service.search(
            DiscoverySearchQuery(text: "x", bpmMin: 120, bpmMax: 125, limit: 50))
        XCTAssertEqual(filtered.state, .ready)
        XCTAssertGreaterThan(filtered.results.count, 0)
        XCTAssertLessThanOrEqual(filtered.results.count, 50)

        // Filter-only over the same scope.
        let filterOnly = await service.search(
            DiscoverySearchQuery(text: "", bpmMin: 120, bpmMax: 122, limit: 50))
        XCTAssertEqual(filterOnly.mode, .filterOnly)
        XCTAssertEqual(filterOnly.state, .ready)
    }
}
#endif
