import GRDB
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// C03 fixtures for the outbox/bootstrap reconciler (IMPLEMENT_CLAP_PLAN.md
/// §3/§4/§11): bootstrap covers ALL existing tracks (not just future
/// imports), bootstrap/outbox replay is idempotent, content replacement
/// restarts the job, and metadata-only edits/deletes do not create spurious
/// re-embeds.
final class DiscoveryReconcilerTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
    }

    @discardableResult
    private func insertTrack(_ queue: DatabaseQueue, title: String = "Song") async throws -> Int64 {
        try await queue.write { db in
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") == 0 {
                try db.execute(
                    sql: """
                        INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                            localIsFolder)
                        VALUES ('local', 'Music', ?, 0, 0, 1)
                        """, arguments: [Date()])
            }
            let sourceID = try Int64.fetchOne(db, sql: "SELECT id FROM source LIMIT 1")!
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, ?, ?)",
                arguments: [sourceID, title, title.lowercased()])
            return db.lastInsertedRowID
        }
    }

    /// Bootstrap must cover tracks that existed BEFORE discovery shipped —
    /// not only future imports (plan §4: "Bootstrap ALL existing core
    /// tracks, not just future imports").
    func testBootstrapCoversAllExistingTracksAcrossPages() async throws {
        let queue = try makeQueue()
        for i in 0..<(DiscoveryReconciler.bootstrapPageSize + 25) {
            try await insertTrack(queue, title: "Song \(i)")
        }
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        XCTAssertEqual(enqueued, DiscoveryReconciler.bootstrapPageSize + 25)

        let jobCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_index_job")!
        }
        XCTAssertEqual(jobCount, DiscoveryReconciler.bootstrapPageSize + 25)
    }

    func testBootstrapIsIdempotent() async throws {
        let queue = try makeQueue()
        try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let first = try await reconciler.bootstrapAllTracks()
        let second = try await reconciler.bootstrapAllTracks()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0, "re-running bootstrap must not duplicate jobs")
    }

    func testTrackInsertedChangeCreatesJobAndDrainsOutbox() async throws {
        let queue = try makeQueue()
        // The v19 `discovery_change_track_inserted` trigger already wrote the
        // outbox row for this insert (Sources/Data/DiscoveryMigrations.swift)
        // — no manual outbox insert needed here.
        let trackID = try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let processed = try await reconciler.processOutbox()
        XCTAssertEqual(processed, 1)

        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        XCTAssertNotNil(job)

        let remainingChanges = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_change")!
        }
        XCTAssertEqual(remainingChanges, 0, "processed outbox rows must be removed")
    }

    /// Metadata-only edits must not create a fresh revision / re-embed
    /// (plan §4: "Do not make every metadata edit re-embed audio").
    func testMetadataUpdateChangeDoesNotTouchExistingJob() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)
        try await reconciler.bootstrapAllTracks()
        let before = try await repo.job(trackId: trackID, pipelineVersion: 1)!

        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO discovery_change (trackId, kind, createdAt) VALUES (?, ?, ?)",
                arguments: [trackID, "trackMetadataUpdated", Date()])
        }
        try await reconciler.processOutbox()

        let after = try await repo.job(trackId: trackID, pipelineVersion: 1)!
        XCTAssertEqual(before.assetRevision, after.assetRevision)
        XCTAssertEqual(before.state, after.state)
        XCTAssertEqual(before.updatedAt, after.updatedAt, "metadata edits must not restart the job")
    }

    /// Content replacement DOES bump the revision and restart the job (plan
    /// §4: "Source replacement changes the revision even if the title is
    /// identical").
    func testAssetContentReplacedRestartsJobWithNewRevision() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)
        try await reconciler.bootstrapAllTracks()

        // Simulate the job having completed once already.
        let claim = try await repo.claimNextJob()!
        try await repo.completeStage(
            jobId: claim.job.id, leaseToken: claim.leaseToken, stage: .embedding, state: .complete)
        try await repo.completeStage(
            jobId: claim.job.id, leaseToken: claim.leaseToken, stage: .musicalAnalysis,
            state: .complete)
        let completed = try await repo.job(trackId: trackID, pipelineVersion: 1)!
        XCTAssertEqual(completed.state, .complete)

        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO discovery_change (trackId, kind, createdAt) VALUES (?, ?, ?)",
                arguments: [trackID, "assetContentReplaced", Date()])
        }
        try await reconciler.processOutbox()

        let restarted = try await repo.job(trackId: trackID, pipelineVersion: 1)!
        XCTAssertEqual(restarted.id, completed.id, "same logical job, restarted")
        XCTAssertEqual(restarted.state, .queued)
        XCTAssertEqual(restarted.embeddingStageState, .pending)
        XCTAssertGreaterThan(restarted.assetRevision ?? 0, completed.assetRevision ?? 0)
    }

    /// trackDeleted/sourceDeleted changes: the FK cascade already removed
    /// the job; the reconciler must still drain (delete) the outbox row
    /// rather than looping on it forever.
    func testDeletedTrackChangeIsDrainedWithoutError() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)
        try await reconciler.bootstrapAllTracks()

        // The v19 `discovery_change_track_deleted` trigger writes the outbox
        // row itself, with trackId NULL (the deleted track's own id cascades
        // away before the AFTER DELETE trigger's INSERT could reference it).
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [trackID])
        }
        let processed = try await reconciler.processOutbox()
        XCTAssertEqual(processed, 1)
        let remaining = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_change")!
        }
        XCTAssertEqual(remaining, 0)
    }
}
