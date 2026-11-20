#if !os(watchOS)
import Foundation
import GRDB
import Testing

@testable import TonearmCore
@testable import TonearmDiscovery

@Suite final class EmbeddingSpaceTests {
    private var cacheURL: URL!

    init() {
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("space-test-\(UUID().uuidString).bin")
    }

    deinit {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// Migrated DB with user rows and a (possibly wrong-dimension) embedding, no space installed.
    private func seededQueue(vectorCount: Int) throws -> (DatabaseQueue, Int64) {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        let trackId = try queue.write { db -> Int64 in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "keep")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(
                db, trackId: t, assetId: a, vector: (0..<vectorCount).map { Float($0 % 7) + 1 })
            try SearchFixture.seedJob(db, trackId: t, state: .complete, embedding: .complete)
            try SearchFixture.seedAnalysis(db, trackId: t, assetId: a, bpm: 120)
            return t
        }
        return (queue, trackId)
    }

    private func count(_ queue: DatabaseQueue, _ table: String) throws -> Int {
        try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    @Test func testFingerprintFormat() {
        let s = EmbeddingSpace.current
        #expect(s.dimensions == 128)
        #expect(
            s.fingerprint ==
            "clap-int4-128-v1:128:b69c830c05cc006e380c2f7ab938c2c561721be868f3a45613982c046db93b7a:"
                + "429a248e33d03b106e4f80a7098c66fdadc022b83eee72710347629fc341fb86:"
                + "df530674afd552bffc04ad38acbabf028dc279408de0a57238a53a3ea763f32a:"
                + "\(s.preprocessingVersion):\(s.samplingVersion)")
        #expect(!s.fingerprint.contains("development-"))
    }

    @Test func test512DimensionalStateIsResetAndUserDataSurvives() throws {
        let (queue, _) = try seededQueue(vectorCount: 512)
        #expect(try EmbeddingSpace.install(on: queue, cacheURL: cacheURL))
        for table in ["discovery_embedding", "discovery_index_job", "discovery_track_analysis",
                      "discovery_window_checkpoint"] {
            #expect(try count(queue, table) == 0, "\(table)")
        }
        for table in ["source", "track", "asset"] {
            #expect(try count(queue, table) == 1, "\(table)")
        }
        let stored = try queue.read { try String.fetchOne($0, sql: "SELECT fingerprint FROM discovery_embedding_space") }
        #expect(stored == EmbeddingSpace.current.fingerprint)
    }

    @Test func testMatchingFingerprintIsNoOp() throws {
        let (queue, _) = try seededQueue(vectorCount: 128)
        #expect(try EmbeddingSpace.install(on: queue, cacheURL: cacheURL))
        try queue.write { db in
            let t = try Int64.fetchOne(db, sql: "SELECT id FROM track")!
            let a = try Int64.fetchOne(db, sql: "SELECT id FROM asset")!
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [Float](repeating: 1, count: 128))
        }
        #expect(!(try EmbeddingSpace.install(on: queue, cacheURL: cacheURL)))
        #expect(try count(queue, "discovery_embedding") == 1)
    }

    @Test func testMismatched128DimensionalFingerprintResetsAndRemovesCache() throws {
        let (queue, _) = try seededQueue(vectorCount: 128)
        try EmbeddingSpace.install(on: queue, cacheURL: cacheURL)
        try queue.write { db in
            let t = try Int64.fetchOne(db, sql: "SELECT id FROM track")!
            let a = try Int64.fetchOne(db, sql: "SELECT id FROM asset")!
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [Float](repeating: 1, count: 128))
        }
        try Data([1]).write(to: cacheURL)
        let other = EmbeddingSpace(
            identifier: "clap-int4-128-v2", dimensions: 128, audioModelSHA256: "a", textModelSHA256: "t",
            projectionSHA256: "p", preprocessingVersion: 1, samplingVersion: 1)
        #expect(try EmbeddingSpace.install(other, on: queue, cacheURL: cacheURL))
        #expect(try count(queue, "discovery_embedding") == 0)
        #expect(try count(queue, "track") == 1)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test func testVectorIndexNeverReturns512DimensionalRow() async throws {
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "wide")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [Float](repeating: 1, count: 512))
        }
        let snap = try await VectorIndex(writer: queue, cacheURL: cacheURL).currentSnapshot()
        #expect(snap.rowCount == 0)
        #expect(snap.dimensions == EmbeddingSpace.current.dimensions)
    }

    @Test func test128DimensionalRowIsQueryable() async throws {
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "ok")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [Float](repeating: 1, count: 128))
        }
        let snap = try await VectorIndex(writer: queue, cacheURL: cacheURL).currentSnapshot()
        #expect(snap.rowCount == 1)
        #expect(snap.dimensions == 128)
    }
}
#endif
