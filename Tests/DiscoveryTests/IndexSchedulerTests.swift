import Foundation
import GRDB
import Testing

@testable import TonearmCore
@testable import TonearmDiscovery

/// A scripted `IndexJobExecuting` that returns outcomes from a queue, one
/// per `processNextUnit` call, so tests can assert the scheduler drives a
/// job exactly the way each outcome implies.
actor ScriptedWorker: IndexJobExecuting {
    private var script: [IndexWorkOutcome]
    private(set) var callCount = 0

    init(_ script: [IndexWorkOutcome]) { self.script = script }

    func processNextUnit(job: DiscoveryIndexJob, leaseToken: String) async -> IndexWorkOutcome {
        callCount += 1
        guard !script.isEmpty else { return .musicalAnalysisStageFinished(.complete) }
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

    @discardableResult
    func mutate(_ body: (inout Value) -> Void) -> Value {
        lock.lock(); defer { lock.unlock() }
        body(&value)
        return value
    }
}

/// Free function (not a method) so it can be called from a `@Sendable`
/// closure without capturing a non-Sendable test instance.
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

@Suite struct IndexSchedulerTests {
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

    @Test func testIdleWhenNoJobsQueued() async throws {
        let queue = try makeQueue()
        let jobs = IndexJobRepository(writer: queue)
        let scheduler = IndexScheduler(jobs: jobs, worker: ScriptedWorker([]))
        let outcome = try await scheduler.tick { nominalForegroundSnapshot() }
        #expect(outcome == .idle)
    }

    @Test func testBlockedWhenUserPausedNeverClaimsAJob() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        var pausedValue = nominalForegroundSnapshot()
        pausedValue.isUserPaused = true
        let paused = pausedValue
        let worker = ScriptedWorker([.musicalAnalysisStageFinished(.complete)])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker)

        let outcome = try await scheduler.tick { paused }
        #expect(outcome == .blocked(.userPaused))
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        #expect(job?.state == .queued)
        let calls = await worker.callCount
        #expect(calls == 0, "paused must never invoke the worker")
    }

    @Test func testDrivesJobToCompletionWithOneAnalysisUnit() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([.musicalAnalysisStageFinished(.complete)])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker)

        let outcome = try await scheduler.tick { nominalForegroundSnapshot() }
        guard case .jobCompleted = outcome else {
            Issue.record("expected jobCompleted, got \(outcome)"); return
        }
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        #expect(job?.state == .complete)
        #expect(job?.musicalAnalysisStageState == .complete)
        let calls = await worker.callCount
        #expect(calls == 1, "one analysis unit per track")
    }

    @Test func testFailedAnalysisMarksTheJobFailedNotComplete() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([.musicalAnalysisStageFinished(.failed)])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker)

        let outcome = try await scheduler.tick { nominalForegroundSnapshot() }
        guard case .jobFailed = outcome else {
            Issue.record("expected jobFailed (terminal), got \(outcome)"); return
        }
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        #expect(job?.musicalAnalysisStageState == .failed)
        #expect(job?.state == .failed)
        let coverage = try await jobs.coverage(pipelineVersion: 1)
        #expect(coverage.complete == 0)
        #expect(coverage.failed == 1)
    }

    @Test func testTransientFailureSchedulesRetryAndStopsTheTick() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([.transientFailure(code: "decodeError", message: "bad frame")])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker)

        let outcome = try await scheduler.tick { nominalForegroundSnapshot() }
        guard case .jobFailed = outcome else {
            Issue.record("expected jobFailed, got \(outcome)"); return
        }
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        #expect(job?.state == .retryScheduled)
        #expect(job?.attemptCount == 1)
    }

    @Test func testWorkerWaitingReasonPersistsAndStopsTheTick() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([.waiting(reason: .waitingForAsset, retryAfterSeconds: nil)])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker)

        let beforeJob = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        let outcome = try await scheduler.tick { nominalForegroundSnapshot() }
        #expect(outcome == .jobWaiting(jobId: beforeJob!.id, reason: .waitingForAsset))
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        #expect(job?.state == .waitingForAsset)
        #expect(job?.attemptCount == 0)
    }

    @Test func testThermalDegradingBeforeTheUnitPreemptsAndReleasesJobToQueuedWithNoPenalty() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([.musicalAnalysisStageFinished(.complete)])
        let checkCount = SendableBox<Int>(0)
        let scheduler = IndexScheduler(jobs: jobs, worker: worker)

        let outcome = try await scheduler.tick {
            let count = checkCount.mutate { $0 += 1 }
            var s = nominalForegroundSnapshot()
            if count >= 2 { s.thermalState = .serious }
            return s
        }

        guard case .jobPreempted(_, let reason) = outcome else {
            Issue.record("expected jobPreempted, got \(outcome)"); return
        }
        #expect(reason == .thermalSerious)
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        #expect(job?.state == .waitingForCooling)
        #expect(job?.attemptCount == 0)
        let calls = await worker.callCount
        #expect(calls == 0, "must preempt before invoking the worker")
    }

    @Test func testPlaybackActiveDoesNotPreemptARunningJob() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([.musicalAnalysisStageFinished(.complete)])
        let checkCount = SendableBox<Int>(0)
        let scheduler = IndexScheduler(jobs: jobs, worker: worker)

        let outcome = try await scheduler.tick {
            let count = checkCount.mutate { $0 += 1 }
            var s = nominalForegroundSnapshot()
            if count >= 2 { s.isPlaybackActive = true }
            return s
        }

        guard case .jobCompleted = outcome else {
            Issue.record("expected jobCompleted — playback must not preempt, got \(outcome)"); return
        }
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        #expect(job?.state == .complete)
    }

    @Test func testRemoteAssetJobIsPreemptedOffWiFiWhenWiFiOnlySettingIsOn() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let assetId = try await queue.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO asset (trackId, kind) VALUES (?, 'remote')",
                arguments: [trackId])
            return db.lastInsertedRowID
        }
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: assetId, assetRevision: 1, pipelineVersion: 1)

        var offWiFiValue = nominalForegroundSnapshot()
        offWiFiValue.remoteIndexingWiFiOnlySetting = true
        offWiFiValue.isOnWiFi = false
        let offWiFi = offWiFiValue
        let worker = ScriptedWorker([.musicalAnalysisStageFinished(.complete)])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker)

        let outcome = try await scheduler.tick { offWiFi }
        guard case .jobPreempted(_, let reason) = outcome else {
            Issue.record("expected jobPreempted, got \(outcome)"); return
        }
        #expect(reason == .remoteSamplingRequiresWiFi)
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        #expect(job?.state == .waitingForNetwork)
        let calls = await worker.callCount
        #expect(calls == 0)
    }

    @Test func testLocalAssetJobIsUnaffectedByWiFiGate() async throws {
        let queue = try makeQueue()
        let trackId = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        var offWiFiValue = nominalForegroundSnapshot()
        offWiFiValue.remoteIndexingWiFiOnlySetting = true
        offWiFiValue.isOnWiFi = false
        let offWiFi = offWiFiValue
        let worker = ScriptedWorker([.musicalAnalysisStageFinished(.complete)])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker)

        let outcome = try await scheduler.tick { offWiFi }
        let job = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        #expect(outcome == .jobCompleted(jobId: job!.id))
    }

    @Test func testOnlyOneJobClaimedPerTick() async throws {
        let queue = try makeQueue()
        let trackA = try await seedTrack(queue)
        let trackB = try await seedTrack(queue)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackA, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
        try await jobs.enqueueOrRestart(
            trackId: trackB, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let worker = ScriptedWorker([.musicalAnalysisStageFinished(.complete)])
        let scheduler = IndexScheduler(jobs: jobs, worker: worker)
        _ = try await scheduler.tick { nominalForegroundSnapshot() }

        let jobA = try await jobs.job(trackId: trackA, pipelineVersion: 1)
        let jobB = try await jobs.job(trackId: trackB, pipelineVersion: 1)
        let states = Set([jobA?.state, jobB?.state])
        #expect(states.contains(.queued))
        #expect(states.contains(.complete))
    }
}
