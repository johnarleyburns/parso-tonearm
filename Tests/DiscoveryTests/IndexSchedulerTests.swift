import GRDB
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// A scripted `IndexJobExecuting` that returns outcomes from a queue, one
/// per `processNextUnit` call, so tests can assert the scheduler drives a
/// job exactly the way each outcome implies (plan §11 C04's own sanctioned
/// "synthetic test encoders for deterministic automation").
actor ScriptedWorker: IndexJobExecuting {
    private var script: [IndexWorkOutcome]
    private(set) var callCount = 0

    init(_ script: [IndexWorkOutcome]) { self.script = script }

    func processNextUnit(job: DiscoveryIndexJob, leaseToken: String) async -> IndexWorkOutcome {
        callCount += 1
        guard !script.isEmpty else { return .embeddingStageFinished(.complete) }
        return script.removeFirst()
    }
}

/// A thread-safe mutable box for test state read/written from inside a
/// `@Sendable` `snapshotProvider` closure (counters, evolving snapshots).
final class SendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    /// Read-modify-write, returning the value AFTER the mutation.
    @discardableResult
    func mutate(_ body: (inout Value) -> Void) -> Value {
        lock.lock(); defer { lock.unlock() }
        body(&value)
        return value
    }
}

/// Free function (not a method) so it can be called from a `@Sendable`
/// closure without capturing a non-Sendable `XCTestCase` instance.
private func nominalForegroundSnapshot() -> DiscoverySchedulingSnapshot {
    DiscoverySchedulingSnapshot(
        appState: .foreground,
        thermalState: .nominal,
        batteryLevel: 0.9,
        isCharging: true,
        isLowPowerModeEnabled: false,
        isPlaybackActive: false,
        isUserPaused: false,
        chargingOnlySetting: false,
        hasBackgroundProcessingGrant: false,
        hasMemoryWarning: false,
        continuousNominalSeconds: 120)
}

final class IndexSchedulerTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
    }

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

    func testIdleWhenNoJobsQueued() async throws {
        let queue = try makeQueue()
        let jobs = IndexJobRepository(writer: queue)
        let scheduler = IndexScheduler(
            jobs: jobs, worker: ScriptedWorker([]), sleeper: { _ in })
        let outcome = try await scheduler.tick { nominalForegroundSnapshot() }
        XCTAssertEqual(outcome, .idle)
    }

    func testBlockedWhenUserPausedNeverClaimsAJob() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        var pausedValue = nominalForegroundSnapshot()
        pausedValue.isUserPaused = true
        let paused = pausedValue
        let worker = ScriptedWorker([.embeddingStageFinished(.complete)])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker, sleeper: { _ in })

        let outcome = try await scheduler.tick { paused }
        XCTAssertEqual(outcome, .blocked(.userPaused))
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        XCTAssertEqual(job?.state, .queued)
        let calls = await worker.callCount
        XCTAssertEqual(calls, 0, "paused must never invoke the worker")
    }

    func testDrivesJobThroughWindowsToCompletion() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([
            .windowCompleted,
            .windowCompleted,
            .embeddingStageFinished(.complete),
            .musicalAnalysisStageFinished(.complete),
        ])
        let sleptDelays = SendableBox<[TimeInterval]>([])
        let scheduler = IndexScheduler(
            jobs: jobs, worker: worker,
            sleeper: { seconds in sleptDelays.mutate { $0.append(seconds) } })

        let outcome = try await scheduler.tick { nominalForegroundSnapshot() }
        guard case .jobCompleted = outcome else {
            return XCTFail("expected jobCompleted, got \(outcome)")
        }
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        XCTAssertEqual(job?.state, .complete)
        XCTAssertEqual(job?.embeddingStageState, .complete)
        XCTAssertEqual(job?.musicalAnalysisStageState, .complete)
        XCTAssertEqual(sleptDelays.get(), [2, 2], "one inter-window delay per completed window")
    }

    func testEmbeddingSuccessWithFailedMusicalAnalysisStillCompletesTheJob() async throws {
        // plan §4: "A musical-analysis failure never blocks embedding-derived
        // search coverage" — the job as a whole still reaches `.complete`.
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([
            .embeddingStageFinished(.complete),
            .musicalAnalysisStageFinished(.failed),
        ])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker, sleeper: { _ in })

        let outcome = try await scheduler.tick { nominalForegroundSnapshot() }
        guard case .jobCompleted = outcome else {
            return XCTFail("expected jobCompleted, got \(outcome)")
        }
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        XCTAssertEqual(job?.musicalAnalysisStageState, .failed)
        XCTAssertEqual(job?.state, .complete)
    }

    func testTransientFailureSchedulesRetryAndStopsTheTick() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([.transientFailure(code: "decodeError", message: "bad frame")])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker, sleeper: { _ in })

        let outcome = try await scheduler.tick { nominalForegroundSnapshot() }
        guard case .jobFailed = outcome else {
            return XCTFail("expected jobFailed, got \(outcome)")
        }
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        XCTAssertEqual(job?.state, .retryScheduled)
        XCTAssertEqual(job?.attemptCount, 1)
    }

    func testWorkerWaitingReasonPersistsAndStopsTheTick() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([.waiting(reason: .waitingForAsset, retryAfterSeconds: nil)])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker, sleeper: { _ in })

        let beforeJob = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        let outcome = try await scheduler.tick { nominalForegroundSnapshot() }
        XCTAssertEqual(
            outcome, .jobWaiting(jobId: beforeJob!.id, reason: .waitingForAsset))
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        XCTAssertEqual(job?.state, .waitingForAsset)
        // Waiting must not consume a retry attempt (plan §11).
        XCTAssertEqual(job?.attemptCount, 0)
    }

    func testThermalDegradingMidRunPreemptsAndReleasesJobToQueuedWithNoPenalty() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        // First unit succeeds under nominal thermal; the ambient snapshot
        // degrades to serious thermal before the SECOND policy check (which
        // happens before every unit, including the one after windowCompleted).
        let worker = ScriptedWorker([.windowCompleted, .windowCompleted])
        let checkCount = SendableBox<Int>(0)
        let scheduler = IndexScheduler(jobs: jobs, worker: worker, sleeper: { _ in })

        let outcome = try await scheduler.tick {
            let count = checkCount.mutate { $0 += 1 }
            var s = nominalForegroundSnapshot()
            if count >= 2 { s.thermalState = .serious }
            return s
        }

        guard case .jobPreempted(_, let reason) = outcome else {
            return XCTFail("expected jobPreempted, got \(outcome)")
        }
        XCTAssertEqual(reason, .thermalSerious)
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        // waitingForCooling is the persisted proxy for thermal gates (no
        // dedicated "preempted" job state exists in the plan's fixed list).
        XCTAssertEqual(job?.state, .waitingForCooling)
        XCTAssertEqual(job?.attemptCount, 0, "preemption must not consume a retry attempt")
    }

    func testPlaybackActiveMidRunReleasesJobToQueuedForImmediateReclaim() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([.windowCompleted, .windowCompleted])
        let checkCount = SendableBox<Int>(0)
        let scheduler = IndexScheduler(jobs: jobs, worker: worker, sleeper: { _ in })

        let outcome = try await scheduler.tick {
            let count = checkCount.mutate { $0 += 1 }
            var s = nominalForegroundSnapshot()
            if count >= 2 { s.isPlaybackActive = true }
            return s
        }

        guard case .jobPreempted(_, let reason) = outcome else {
            return XCTFail("expected jobPreempted, got \(outcome)")
        }
        XCTAssertEqual(reason, .playbackActive)
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        XCTAssertEqual(job?.state, .queued, "no dedicated job state for playback priority")
        XCTAssertNil(job?.leaseToken)
    }

    func testOnlyOneJobClaimedPerTick() async throws {
        // plan §6: "Only ONE analysis job executes at a time" — a second
        // enqueued track is untouched by a single tick.
        let queue = try makeQueue()
        let trackA = try await seedTrack(queue)
        let trackB = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackA, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
        try await jobs.enqueueOrRestart(
            trackId: trackB, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        // Both stages must reach a terminal state for the job to become
        // `.isComplete` (plan §4). Without the second outcome here, the
        // scripted worker's "script exhausted" fallback keeps returning
        // `.embeddingStageFinished(.complete)` forever — already terminal,
        // so it never changes anything — and `IndexScheduler.tick`'s
        // `while true` loop (which only sleeps on `.windowCompleted`) spins
        // in a tight, unthrottled loop indefinitely. This was caught by an
        // actual hang, not just review: an earlier version of this test
        // omitted `.musicalAnalysisStageFinished` and never terminated.
        let worker = ScriptedWorker([
            .embeddingStageFinished(.complete), .musicalAnalysisStageFinished(.complete),
        ])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker, sleeper: { _ in })
        _ = try await scheduler.tick { nominalForegroundSnapshot() }

        let jobA = try await jobs.job(trackId: trackA, pipelineVersion: 1)
        let jobB = try await jobs.job(trackId: trackB, pipelineVersion: 1)
        // Whichever one was claimed (createdAt/priority ordering: A first)
        // finished; the other remains queued and untouched.
        let states = Set([jobA?.state, jobB?.state])
        XCTAssertTrue(states.contains(.queued))
        XCTAssertTrue(states.contains(.complete) || states.contains(.running))
    }
}
