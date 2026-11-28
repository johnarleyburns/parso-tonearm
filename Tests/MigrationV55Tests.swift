import Foundation
import GRDB
import Testing

@testable import TonearmCore

/// v55: mood/CLAP removal. The semantic index's tables and the index job's
/// embedding-stage columns are gone; BPM/key/energy analysis is the only
/// derived track content left.
@Suite struct MigrationV55Tests {
    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v54").migrate(queue)
        return queue
    }

    private func seed(_ queue: DatabaseQueue) throws -> (trackId: Int64, assetId: Int64) {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit)
                    VALUES ('local', 'Lib', ?, 0, 0)
                    """, arguments: [Date()])
            let sourceId = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey, indexed) VALUES (?, 'T', 'a', 1)",
                arguments: [sourceId])
            let trackId = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO asset (trackId, kind, relPath, sizeBytes) VALUES (?, 'localRef', 'x', 1)",
                arguments: [trackId])
            let assetId = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO discovery_embedding
                        (trackId, assetId, assetRevision, modelVersion, preprocessingVersion,
                         samplingVersion, dimensions, quantizedVector, scale, completedAt)
                    VALUES (?, ?, 1, 1, 1, 1, 1, x'00', 1.0, ?)
                    """, arguments: [trackId, assetId, Date()])
            try db.execute(
                sql: """
                    INSERT INTO discovery_track_analysis
                        (trackId, assetId, assetRevision, analysisVersion, bpm, key, energy, completedAt)
                    VALUES (?, ?, 1, 2, 124, '8A', 6.0, ?)
                    """, arguments: [trackId, assetId, Date()])
            try db.execute(
                sql: """
                    INSERT INTO discovery_index_job
                        (id, trackId, selectedAssetId, assetRevision, pipelineVersion, state,
                         priority, createdAt, updatedAt, attemptCount, completedWindows,
                         totalWindows, embeddingStageState, musicalAnalysisStageState)
                    VALUES (?, ?, ?, 1, 1, 'waitingForModel', 0, ?, ?, 0, 3, 4, 'complete', 'pending')
                    """, arguments: [UUID().uuidString, trackId, assetId, Date(), Date()])
            return (trackId, assetId)
        }
    }

    @Test func testV55DropsSemanticTablesAndEmbeddingJobColumns() throws {
        let queue = try makeQueue()
        let ids = try seed(queue)
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            #expect(try !db.tableExists("discovery_embedding"))
            #expect(try !db.tableExists("discovery_window_checkpoint"))
            #expect(try !db.tableExists("discovery_embedding_space"))

            let trackColumns = Set(try db.columns(in: "track").map(\.name))
            #expect(!trackColumns.contains("indexed"))

            let jobColumns = Set(try db.columns(in: "discovery_index_job").map(\.name))
            #expect(!jobColumns.contains("embeddingStageState"))
            #expect(!jobColumns.contains("completedWindows"))
            #expect(!jobColumns.contains("totalWindows"))
            #expect(jobColumns.contains("musicalAnalysisStageState"))

            let job = try Row.fetchOne(
                db, sql: "SELECT state, musicalAnalysisStageState FROM discovery_index_job")
            #expect(job?["state"] as String? == "queued")
            #expect(job?["musicalAnalysisStageState"] as String? == "pending")

            // The surviving BPM/key/energy row is preserved untouched.
            let analysis = try DiscoveryTrackAnalysis.fetchOne(db, key: ids.trackId)
            #expect(analysis?.bpm == 124)
            #expect(analysis?.key == "8A")
            #expect(analysis?.energy == 6.0)
        }
    }

    @Test func testV55RemovesLegacyMoodStarterSource() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit)
                    VALUES ('local', 'Mood Starter', ?, 0, 0)
                    """, arguments: [Date()])
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM source WHERE title = 'Mood Starter'")
            #expect(count == 0)
        }
    }

    @Test func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }
}
