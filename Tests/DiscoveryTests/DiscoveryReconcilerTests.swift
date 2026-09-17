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

    // MARK: - Downloaded/on-device only (real report: "2631 tracks waiting
    // on their audio file... I want to only index downloaded / on-device
    // tracks")

    @discardableResult
    private func insertAsset(
        _ queue: DatabaseQueue, trackId: Int64, kind: String, relPath: String? = nil,
        remoteURL: String? = nil
    ) async throws -> Int64 {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO asset (trackId, kind, relPath, remoteURL) VALUES (?, ?, ?, ?)",
                arguments: [trackId, kind, relPath, remoteURL])
            return db.lastInsertedRowID
        }
    }

    /// A track whose only asset is a bare remote/cloud original (never
    /// downloaded) must not get an index job at all — the old behavior
    /// created one anyway and it sat in `waitingForAsset` permanently,
    /// since nothing was ever going to make a network-only asset locally
    /// resolvable on its own.
    func testBootstrapSkipsATrackWhoseOnlyAssetIsRemote() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        try await insertAsset(
            queue, trackId: trackID, kind: "remote", remoteURL: "https://example.com/song.mp3")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        XCTAssertEqual(enqueued, 0, "a remote-only track must not be enqueued for indexing")
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        XCTAssertNil(job)
    }

    /// A track with a real local asset (relPath) is unaffected — it is
    /// still eligible and gets that asset selected, exactly as before.
    func testBootstrapStillEnqueuesATrackWithARealLocalAsset() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        let assetID = try await insertAsset(
            queue, trackId: trackID, kind: "localRef", relPath: "song.m4a")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        XCTAssertEqual(enqueued, 1)
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        XCTAssertEqual(job?.selectedAssetId, assetID)
    }

    /// A track with NO asset rows yet (a local import still writing its
    /// asset) stays eligible with a `nil` selected asset, same as before —
    /// only a track whose assets ALL resolve to remote/cloud is skipped.
    func testBootstrapStillEnqueuesATrackWithNoAssetRowsYet() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        XCTAssertEqual(enqueued, 1)
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        XCTAssertNotNil(job)
        XCTAssertNil(job?.selectedAssetId)
    }

    /// `remoteOnlyTrackCount()` feeds the Settings confirmation dialog's
    /// data-cost estimate — it must count exactly the tracks
    /// `assetSelection` treats as ineligible (remote-only), never a track
    /// that already has a real local asset or one with no asset rows yet
    /// (still eligible/pending, not "remote-only").
    func testRemoteOnlyTrackCountMatchesIneligibleTracks() async throws {
        let queue = try makeQueue()
        let remoteOnly = try await insertTrack(queue, title: "Remote")
        try await insertAsset(
            queue, trackId: remoteOnly, kind: "remote", remoteURL: "https://example.com/a.mp3")
        let local = try await insertTrack(queue, title: "Local")
        try await insertAsset(queue, trackId: local, kind: "localRef", relPath: "b.m4a")
        let noAssetYet = try await insertTrack(queue, title: "Pending")
        _ = noAssetYet

        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let count = try await reconciler.remoteOnlyTrackCount()
        XCTAssertEqual(count, 1)
    }

    /// A `trackInserted` outbox event for a remote-only track is drained
    /// (no infinite outbox loop) without ever creating a job.
    func testTrackInsertedOutboxEventSkipsARemoteOnlyTrack() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        try await insertAsset(
            queue, trackId: trackID, kind: "remote", remoteURL: "https://example.com/song.mp3")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        try await reconciler.processOutbox()
        let remainingChanges = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_change")!
        }
        XCTAssertEqual(remainingChanges, 0, "the outbox rows must still be drained")
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        XCTAssertNil(job)
    }

    /// Real-installs cleanup: `pruneJobsForUndownloadedTracks()` removes an
    /// existing `waitingForAsset` job for a track that is (and always was)
    /// remote-only, but leaves alone a `waitingForAsset` job for a track
    /// that genuinely has a local asset (some other, real wait reason).
    func testPruneRemovesOnlyJobsForTracksWithNoLocalAsset() async throws {
        let queue = try makeQueue()
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let remoteTrackID = try await insertTrack(queue, title: "Remote Song")
        try await insertAsset(
            queue, trackId: remoteTrackID, kind: "remote",
            remoteURL: "https://example.com/song.mp3")
        let remoteJob = try await repo.enqueueOrRestart(
            trackId: remoteTrackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let localTrackID = try await insertTrack(queue, title: "Local Song")
        let localAssetID = try await insertAsset(
            queue, trackId: localTrackID, kind: "localRef", relPath: "song.m4a")
        let localJob = try await repo.enqueueOrRestart(
            trackId: localTrackID, selectedAssetId: localAssetID, assetRevision: 1,
            pipelineVersion: 1)

        // Drive both jobs to `.waitingForAsset` directly (a full claim/lease
        // round trip isn't what this test is about, and `claimNextJob`'s
        // immediate-reclaim-on-null-nextAttemptAt behavior makes claiming
        // both jobs in a fixed order unreliable here).
        for jobId in [remoteJob.id, localJob.id] {
            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE discovery_index_job SET state = 'waitingForAsset' WHERE id = ?",
                    arguments: [jobId])
            }
        }

        let pruned = try await reconciler.pruneJobsForUndownloadedTracks()
        XCTAssertEqual(pruned, 1)
        let remainingRemoteJob = try await repo.job(id: remoteJob.id)
        XCTAssertNil(remainingRemoteJob, "the remote-only track's job must be gone")
        let remainingLocalJob = try await repo.job(id: localJob.id)
        XCTAssertNotNil(remainingLocalJob, "a track with a real local asset must be untouched")
        XCTAssertEqual(remainingLocalJob?.state, .waitingForAsset)
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
