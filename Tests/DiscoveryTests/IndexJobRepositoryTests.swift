import GRDB
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// A thread-safe injectable test clock. `IndexJobRepository` takes a plain
/// `() -> Date` closure; tests need to mutate "now" from the main test body
/// while the closure itself is invoked from the repository's own actor
/// context, so the box needs to be Sendable across that boundary.
final class MutableTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }

    func set(_ newDate: Date) {
        lock.lock(); defer { lock.unlock() }
        date = newDate
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }
}

/// C03 fixtures: leases, retry backoff, recovery-across-relaunch and
/// idempotent enqueue (IMPLEMENT_CLAP_PLAN.md §3/§11).
final class IndexJobRepositoryTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
    }

    /// Insert one bare track (no source table needed for job-queue tests
    /// since discovery_index_job only FKs to track/asset).
    private func seedTrack(_ queue: DatabaseQueue) async throws -> Int64 {
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                        localIsFolder)
                    VALUES ('local', 'Music', ?, 0, 0, 1)
                    """, arguments: [Date()])
            let sourceID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, 'Song', 'song')",
                arguments: [sourceID])
            return db.lastInsertedRowID
        }
    }

    private func seedAsset(_ queue: DatabaseQueue, trackId: Int64) async throws -> Int64 {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO asset (trackId, kind, relPath) VALUES (?, 'localFile', 'song.m4a')",
                arguments: [trackId])
            return db.lastInsertedRowID
        }
    }

    func testEnqueueIsIdempotentUntilRestartRequested() async throws {
        let queue = try makeQueue()
        let trackID = try await seedTrack(queue)
        let assetID = try await seedAsset(queue, trackId: trackID)
        let repo = IndexJobRepository(writer: queue)

        let first = try await repo.enqueueOrRestart(
            trackId: trackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
        let second = try await repo.enqueueOrRestart(
            trackId: trackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
        XCTAssertEqual(first.id, second.id, "same (track, pipelineVersion) must not duplicate a job")

        let restarted = try await repo.enqueueOrRestart(
            trackId: trackID, selectedAssetId: assetID, assetRevision: 2, pipelineVersion: 1,
            restart: true)
        XCTAssertEqual(restarted.id, first.id, "restart reuses the same logical job")
        XCTAssertEqual(restarted.assetRevision, 2)
        XCTAssertEqual(restarted.state, .queued)
        XCTAssertEqual(restarted.attemptCount, 0)
    }

    func testClaimAssignsLeaseAndSecondClaimSeesNothingUntilExpiry() async throws {
        let queue = try makeQueue()
        let trackID = try await seedTrack(queue)
        let clock = MutableTestClock(Date())
        let repo = IndexJobRepository(writer: queue, clock: clock.now)
        _ = try await repo.enqueueOrRestart(
            trackId: trackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        guard let claim = try await repo.claimNextJob(leaseDuration: 60) else {
            return XCTFail("expected a claimable job")
        }
        XCTAssertEqual(claim.job.state, .running)

        // A concurrent claim attempt before the lease expires must see nothing.
        let concurrentClaim = try await repo.claimNextJob(leaseDuration: 60)
        XCTAssertNil(concurrentClaim)

        // Advance the clock past lease expiry: the crashed claim becomes
        // reclaimable (plan §7: recover after expiration/process death).
        clock.advance(by: 61)
        guard let reclaim = try await repo.claimNextJob(leaseDuration: 60) else {
            return XCTFail("expected the expired lease to be reclaimable")
        }
        XCTAssertEqual(reclaim.job.id, claim.job.id)
        XCTAssertNotEqual(reclaim.leaseToken, claim.leaseToken)
    }

    func testStaleTokenMutationsAreDiscarded() async throws {
        let queue = try makeQueue()
        let trackID = try await seedTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        _ = try await repo.enqueueOrRestart(
            trackId: trackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
        let claim = try await repo.claimNextJob()!

        // Simulate a second claimant taking over (e.g. after our lease
        // conceptually expired and another worker raced us).
        try await repo.recordTransientFailure(
            jobId: claim.job.id, leaseToken: "not-the-real-token", errorCode: "x",
            errorMessage: nil)

        let job = try await repo.job(id: claim.job.id)!
        XCTAssertEqual(job.state, .running, "a stale lease token must not mutate the job")
        XCTAssertEqual(job.attemptCount, 0)
    }

    func testRetryBackoffEscalatesThenFailsAfterFiveAttempts() async throws {
        let queue = try makeQueue()
        let trackID = try await seedTrack(queue)
        let clock = MutableTestClock(Date())
        let repo = IndexJobRepository(writer: queue, clock: clock.now)
        _ = try await repo.enqueueOrRestart(
            trackId: trackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        var jobId = ""
        for attempt in 1...IndexJobRepository.maxTransientFailures {
            let beforeFailure = clock.now()
            let claim = try await repo.claimNextJob()!
            jobId = claim.job.id
            try await repo.recordTransientFailure(
                jobId: claim.job.id, leaseToken: claim.leaseToken, errorCode: "decode",
                errorMessage: "boom")
            let job = try await repo.job(id: claim.job.id)!
            if attempt < IndexJobRepository.maxTransientFailures {
                XCTAssertEqual(job.state, .retryScheduled)
                let expectedDelay = IndexJobRepository.retryBackoffSeconds[
                    min(attempt - 1, IndexJobRepository.retryBackoffSeconds.count - 1)]
                XCTAssertEqual(
                    job.nextAttemptAt!.timeIntervalSince(beforeFailure), expectedDelay,
                    accuracy: 0.001)
                // Advance clock so the next attempt is actually claimable.
                clock.set(job.nextAttemptAt!.addingTimeInterval(1))
            } else {
                XCTAssertEqual(job.state, .failed)
                XCTAssertNil(job.nextAttemptAt)
            }
        }

        // A failed job is not auto-retried even after time passes.
        clock.advance(by: 10_000)
        let noClaim = try await repo.claimNextJob()
        XCTAssertNil(noClaim)

        // Manual retry resets it.
        try await repo.manualRetry(jobId: jobId)
        let retried = try await repo.job(id: jobId)!
        XCTAssertEqual(retried.state, .queued)
        XCTAssertEqual(retried.attemptCount, 0)
    }

    func testWaitingDoesNotConsumeRetryAttempt() async throws {
        let queue = try makeQueue()
        let trackID = try await seedTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        _ = try await repo.enqueueOrRestart(
            trackId: trackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
        let claim = try await repo.claimNextJob()!

        try await repo.markWaiting(
            jobId: claim.job.id, leaseToken: claim.leaseToken, reason: .waitingForPower,
            retryAfter: 30)

        let job = try await repo.job(id: claim.job.id)!
        XCTAssertEqual(job.state, .waitingForPower)
        XCTAssertEqual(job.attemptCount, 0, "waiting must not consume a retry attempt")
    }

    func testRecoverStaleLeasesAtLaunchResetsRunningToQueued() async throws {
        let queue = try makeQueue()
        let trackID = try await seedTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        _ = try await repo.enqueueOrRestart(
            trackId: trackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
        let claim = try await repo.claimNextJob()!
        let claimedJob = try await repo.job(id: claim.job.id)!
        XCTAssertEqual(claimedJob.state, .running)

        // Simulate process relaunch: a fresh repository over the same DB.
        let relaunchedRepo = IndexJobRepository(writer: queue)
        let result = try await relaunchedRepo.recoverStaleLeasesAtLaunch()
        XCTAssertEqual(result.resetJobCount, 1)

        let recovered = try await relaunchedRepo.job(id: claim.job.id)!
        XCTAssertEqual(recovered.state, .queued)
        XCTAssertNil(recovered.leaseToken)
        XCTAssertNil(recovered.leaseExpiresAt)
    }

    func testWindowCheckpointProgressAndStageCompletionIsIndependent() async throws {
        let queue = try makeQueue()
        let trackID = try await seedTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        _ = try await repo.enqueueOrRestart(
            trackId: trackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
        let claim = try await repo.claimNextJob()!

        try await repo.recordWindowCompletion(
            jobId: claim.job.id, leaseToken: claim.leaseToken,
            checkpoint: DiscoveryWindowCheckpoint(
                jobId: claim.job.id, revisionSignature: "r1", windowIndex: 0, startSeconds: 0,
                embeddingVector: Data([1, 2, 3]), poolingWeight: 1, completedAt: Date()),
            totalWindows: 1)

        let indices = try await repo.completedWindowIndices(jobId: claim.job.id)
        XCTAssertEqual(indices, [0])

        // Musical analysis fails, but embedding completing alone still marks
        // the job overall complete (plan §4: musicalAnalysisStageState may
        // be terminal-failed while embedding coverage is independently true).
        try await repo.completeStage(
            jobId: claim.job.id, leaseToken: claim.leaseToken, stage: .musicalAnalysis,
            state: .failed)
        var job = try await repo.job(id: claim.job.id)!
        XCTAssertEqual(job.state, .running, "not complete until embedding stage also terminal")

        try await repo.completeStage(
            jobId: claim.job.id, leaseToken: claim.leaseToken, stage: .embedding, state: .complete)
        job = try await repo.job(id: claim.job.id)!
        XCTAssertEqual(job.state, .complete)
        XCTAssertTrue(job.isComplete)
    }

    func testCoverageCounts() async throws {
        let queue = try makeQueue()
        let clock = MutableTestClock(Date())
        let repo = IndexJobRepository(writer: queue, clock: clock.now)
        var trackIDs: [Int64] = []
        for _ in 0..<4 { trackIDs.append(try await seedTrack(queue)) }

        // Distinct priorities make claim order deterministic: the highest
        // priority is always claimed first regardless of the other jobs'
        // (queued/retryScheduled) states.
        _ = try await repo.enqueueOrRestart(
            trackId: trackIDs[0], selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1,
            priority: 100)
        _ = try await repo.enqueueOrRestart(
            trackId: trackIDs[1], selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1,
            priority: 50)
        _ = try await repo.enqueueOrRestart(
            trackId: trackIDs[2], selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
        _ = try await repo.enqueueOrRestart(
            trackId: trackIDs[3], selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        // Complete trackIDs[0]'s job (highest priority, so it is always
        // claimed first).
        let claimA = try await repo.claimNextJob()!
        let jobA = try await repo.job(trackId: trackIDs[0], pipelineVersion: 1)!
        XCTAssertEqual(claimA.job.id, jobA.id)
        try await repo.completeStage(
            jobId: claimA.job.id, leaseToken: claimA.leaseToken, stage: .embedding, state: .complete)
        try await repo.completeStage(
            jobId: claimA.job.id, leaseToken: claimA.leaseToken, stage: .musicalAnalysis,
            state: .complete)

        // Drive trackIDs[1]'s job (next-highest priority) to terminal
        // failure via full retry escalation.
        let targetJobId = try await repo.job(trackId: trackIDs[1], pipelineVersion: 1)!.id
        for _ in 0..<IndexJobRepository.maxTransientFailures {
            let claim = try await repo.claimNextJob()!
            XCTAssertEqual(claim.job.id, targetJobId, "priority 50 must always outrank priority 0")
            try await repo.recordTransientFailure(
                jobId: claim.job.id, leaseToken: claim.leaseToken, errorCode: "x",
                errorMessage: nil)
            if let nextAttemptAt = try await repo.job(id: targetJobId)!.nextAttemptAt {
                clock.set(nextAttemptAt.addingTimeInterval(1))
            }
        }
        let finalFailingJob = try await repo.job(id: targetJobId)!
        XCTAssertEqual(finalFailingJob.state, .failed)

        let coverage = try await repo.coverage(pipelineVersion: 1)
        XCTAssertEqual(coverage.total, 4)
        XCTAssertEqual(coverage.complete, 1)
        XCTAssertEqual(coverage.failed, 1)
        XCTAssertEqual(coverage.queuedOrRunning, 2)
    }

    /// C07 "Retry failed" action (plan §10): every `.failed` job for the
    /// pipeline is re-queued; queued/running jobs are untouched.
    func testRetryAllFailedRequeuesOnlyFailedJobs() async throws {
        let queue = try makeQueue()
        let clock = MutableTestClock(Date())
        let repo = IndexJobRepository(writer: queue, clock: clock.now)

        _ = try await seedTrack(queue)  // creates the source row the FK needs

        var jobIds: [String] = []
        for i in 0..<3 {
            let trackID = try await queue.write { db -> Int64 in
                try db.execute(
                    sql: "INSERT INTO track (sourceId, title, sortKey) VALUES "
                        + "((SELECT id FROM source LIMIT 1), 'S\(i)', 's\(i)')")
                return db.lastInsertedRowID
            }
            let job = try await repo.enqueueOrRestart(
                trackId: trackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
            jobIds.append(job.id)
        }

        // Force the first two jobs terminal-failed (as five transient failures
        // would); leave the third queued.
        let failedIds = Array(jobIds.prefix(2))
        try await queue.write { db in
            for id in failedIds {
                try db.execute(
                    sql: "UPDATE discovery_index_job SET state='failed', attemptCount=5, "
                        + "errorCode='x', errorMessage='boom' WHERE id=?",
                    arguments: [id])
            }
        }

        let before = try await repo.coverage(pipelineVersion: 1)
        XCTAssertEqual(before.failed, 2)
        XCTAssertEqual(before.queuedOrRunning, 1)

        let requeued = try await repo.retryAllFailed(pipelineVersion: 1)
        XCTAssertEqual(requeued, 2)

        let after = try await repo.coverage(pipelineVersion: 1)
        XCTAssertEqual(after.failed, 0)
        XCTAssertEqual(after.queuedOrRunning, 3)
        for id in failedIds {
            let job = try await repo.job(id: id)!
            XCTAssertEqual(job.state, .queued)
            XCTAssertEqual(job.attemptCount, 0)
            XCTAssertNil(job.errorCode)
        }
    }
}
