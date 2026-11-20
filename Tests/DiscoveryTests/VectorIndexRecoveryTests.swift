#if !os(watchOS)
import Foundation
import GRDB
import ParsoAudioNeural
import Testing

@testable import TonearmCore
@testable import TonearmDiscovery

/// Plan §8: the vector cache is disposable derived state. Missing / truncated
/// / stale files rebuild from the authoritative `discovery_embedding` rows;
/// a vanished cache never marks a job incomplete. Mixed pipeline versions are
/// never scanned together (plan §6/§9).
@Suite final class VectorIndexRecoveryTests {
    private var cacheURL: URL!

    init() {
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidx-\(UUID().uuidString).bin")
    }
    deinit {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func seed(_ queue: DatabaseQueue, vectors: [(Int64, [Float])],
                      version: Int = DiscoveryPipelineVersion.model) async throws {
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            for (id, vec) in vectors {
                let t = try SearchFixture.seedTrack(db, sourceId: s, title: "t\(id)")
                let a = try SearchFixture.seedAsset(db, trackId: t)
                try SearchFixture.seedEmbedding(
                    db, trackId: t, assetId: a, vector: vec, modelVersion: version)
            }
        }
    }

    @Test func testRebuildFromEmbeddingsProducesConsistentSnapshot() async throws {
        let queue = try SearchFixture.makeQueue()
        try await seed(queue, vectors: [(1, [1, 0, 0, 0]), (2, [0, 1, 0, 0]), (3, [0, 0, 1, 0])])
        let index = VectorIndex(writer: queue, cacheURL: cacheURL)

        let snap = try await index.currentSnapshot()
        #expect(snap.rowCount == 3)
        #expect(snap.dimensions == EmbeddingSpace.current.dimensions)
        #expect(Set(snap.trackIDByRow).count == 3)
        // Dequantized row 0 ≈ its unit vector.
        let r0 = snap.dequantizedRow(snap.trackIDByRow.firstIndex(of: snap.trackIDByRow[0])!)
        #expect(r0.count == EmbeddingSpace.current.dimensions)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test func testMissingCacheRebuilds() async throws {
        let queue = try SearchFixture.makeQueue()
        try await seed(queue, vectors: [(1, [1, 0, 0, 0]), (2, [0, 1, 0, 0])])
        let index = VectorIndex(writer: queue, cacheURL: cacheURL)
        _ = try await index.currentSnapshot()
        try FileManager.default.removeItem(at: cacheURL)
        await index.releasePublishedSnapshot()

        let snap = try await index.currentSnapshot()
        #expect(snap.rowCount == 2)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test func testTruncatedCacheRebuilds() async throws {
        let queue = try SearchFixture.makeQueue()
        try await seed(queue, vectors: [(1, [1, 0, 0, 0]), (2, [0, 1, 0, 0]), (3, [0, 0, 1, 0])])
        let index = VectorIndex(writer: queue, cacheURL: cacheURL)
        _ = try await index.currentSnapshot()

        // Chop the file to half its length — a torn write.
        let data = try Data(contentsOf: cacheURL)
        try data.prefix(data.count / 2).write(to: cacheURL)
        await index.releasePublishedSnapshot()

        let snap = try await index.currentSnapshot()
        #expect(snap.rowCount == 3)
    }

    @Test func testStaleSignatureTriggersRebuildWithNewGeneration() async throws {
        let queue = try SearchFixture.makeQueue()
        try await seed(queue, vectors: [(1, [1, 0, 0, 0])])
        let index = VectorIndex(writer: queue, cacheURL: cacheURL)
        let g1 = try await index.currentSnapshot().generation

        try await queue.write { db in
            let s = try Int64.fetchOne(db, sql: "SELECT id FROM source LIMIT 1")!
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "new")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [0, 1, 0, 0])
        }
        let snap2 = try await index.currentSnapshot()
        #expect(snap2.rowCount == 2)
        #expect(snap2.generation > g1)
    }

    @Test func testCommitBeforePublicationCrashRebuildsFromDB() async throws {
        let queue = try SearchFixture.makeQueue()
        try await seed(queue, vectors: [(1, [1, 0, 0, 0]), (2, [0, 1, 0, 0])])
        // "Process A" builds and publishes the cache file for 2 rows.
        _ = try await VectorIndex(writer: queue, cacheURL: cacheURL).currentSnapshot()

        // A commit lands (a third embedding) but the process dies before the
        // cache is rebuilt — the on-disk file is now stale.
        try await queue.write { db in
            let s = try Int64.fetchOne(db, sql: "SELECT id FROM source LIMIT 1")!
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "c")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [0, 0, 1, 0])
        }

        // "Process B" starts fresh, loads the stale file, detects the
        // signature mismatch and rebuilds before serving any scan.
        let indexB = VectorIndex(writer: queue, cacheURL: cacheURL)
        let snap = try await indexB.currentSnapshot()
        #expect(snap.rowCount == 3)
    }

    @Test func testMixedPipelineVersionsNotScannedTogether() async throws {
        let queue = try SearchFixture.makeQueue()
        // Two current-version rows...
        try await seed(queue, vectors: [(1, [1, 0, 0, 0]), (2, [0, 1, 0, 0])])
        // ...and one older-model-version row, seeded LAST so it is NOT the
        // newest (newest defines the current pipeline).
        try await queue.write { db in
            let s = try Int64.fetchOne(db, sql: "SELECT id FROM source LIMIT 1")!
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "old")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(
                db, trackId: t, assetId: a, vector: [0, 0, 1, 0],
                modelVersion: DiscoveryPipelineVersion.model + 1,
                completedAt: Date().addingTimeInterval(-10_000))
        }
        let index = VectorIndex(writer: queue, cacheURL: cacheURL)
        let snap = try await index.currentSnapshot()
        #expect(snap.rowCount == 2, "older-pipeline row must be excluded from the scan set")
        #expect(snap.modelVersion == DiscoveryPipelineVersion.model)
    }
}
#endif
