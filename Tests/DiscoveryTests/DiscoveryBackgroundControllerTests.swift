#if !os(watchOS)
import AVFoundation
import GRDB
import ParsoAudioNeural
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// C05 fault-injection matrix (IMPLEMENT_CLAP_PLAN.md §7/§11 C05): the
/// portable `DiscoveryBackgroundController` — the split-out owner of the iOS
/// BackgroundTasks lifecycle — driven against an injected
/// `BackgroundTaskScheduling` fake, the REAL `IndexJobRepository` /
/// `BoundedIndexWorker` / `DiscoveryReconciler`, real on-disk WAV fixtures
/// and a deterministic synthetic CLAP encoder. No real `BGTaskScheduler` and
/// no granted iOS task are needed to exercise:
///
///  - registration (idempotent, result recorded),
///  - `BGProcessingTaskRequest` submission + coalescing (never two
///    outstanding for the identifier), submission-error handling,
///  - a granted drain that completes the task exactly once,
///  - task expiration mid-drain (durable checkpoints survive, job resumes),
///  - background grant revoked mid-run (job released, no retry penalty),
///  - charging lost mid-run (job parks `waitingForPower`),
///  - thermal serious mid-run (job parks `waitingForCooling`),
///  - `discovery_runtime` telemetry (last run / stop reason / coverage
///    snapshot / next scheduled).
final class DiscoveryBackgroundControllerTests: XCTestCase {
    // MARK: - Fakes

    private final class FakeInvocation: BackgroundTaskInvocation, @unchecked Sendable {
        let identifier: String
        private let lock = NSLock()
        private var expiration: (@Sendable () -> Void)?
        private(set) var completeCount = 0
        private(set) var lastSuccess: Bool?

        init(identifier: String) { self.identifier = identifier }

        func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.lock(); expiration = handler; lock.unlock()
        }
        func complete(success: Bool) {
            lock.lock(); completeCount += 1; lastSuccess = success; lock.unlock()
        }
        func fireExpiration() {
            lock.lock(); let h = expiration; lock.unlock()
            h?()
        }
    }

    private struct SubmitError: Error {}

    private final class FakeScheduler: BackgroundTaskScheduling, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (any BackgroundTaskInvocation) -> Void)?
        private(set) var registerCallCount = 0
        private(set) var submittedRequests: [BackgroundProcessingRequest] = []
        private(set) var cancelCount = 0
        var shouldFailSubmit = false

        func register(
            identifier: String,
            launchHandler: @escaping @Sendable (any BackgroundTaskInvocation) -> Void
        ) -> Bool {
            lock.lock(); registerCallCount += 1; handler = launchHandler; lock.unlock()
            return true
        }
        func submit(_ request: BackgroundProcessingRequest) throws {
            lock.lock(); defer { lock.unlock() }
            if shouldFailSubmit { throw SubmitError() }
            // Coalesce by identifier — the real BGTaskScheduler replaces a
            // pending request for the same identifier.
            submittedRequests.removeAll { $0.identifier == request.identifier }
            submittedRequests.append(request)
        }
        func cancel(identifier: String) {
            lock.lock(); cancelCount += 1
            submittedRequests.removeAll { $0.identifier == identifier }
            lock.unlock()
        }
        /// Simulate iOS launching the registered handler with a granted task.
        func launch(_ invocation: FakeInvocation) {
            lock.lock(); let h = handler; lock.unlock()
            h?(invocation)
        }
        var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return submittedRequests.count }
        var lastRequest: BackgroundProcessingRequest? {
            lock.lock(); defer { lock.unlock() }; return submittedRequests.last
        }
    }

    /// Mutable scheduling snapshot the scheduler policy reads every tick, with
    /// a read counter so a test can inject a condition change at a precise
    /// point mid-drain (deterministic — no timing).
    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snap: DiscoverySchedulingSnapshot
        private(set) var reads = 0
        var onRead: (@Sendable (Int, SnapshotBox) -> Void)?

        init(_ snap: DiscoverySchedulingSnapshot) { self.snap = snap }

        func snapshot() -> DiscoverySchedulingSnapshot {
            lock.lock(); reads += 1; let r = reads; let s = snap; lock.unlock()
            onRead?(r, self)
            return s
        }
        func mutate(_ f: (inout DiscoverySchedulingSnapshot) -> Void) {
            lock.lock(); f(&snap); lock.unlock()
        }
    }

    // MARK: - Harness

    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
    }

    private func spec() -> EmbeddingModelSpec {
        let meta = EmbeddingModelSpec.musicCLAPMetadata
        let bins = meta.fftSize / 2 + 1
        return EmbeddingModelSpec.musicCLAP(
            melFilterBank: [Float](repeating: 0.01, count: bins * meta.melBins))
    }

    private func backgroundSnapshot(
        charging: Bool = true, grant: Bool = true,
        thermal: DiscoveryThermalState = .nominal
    ) -> DiscoverySchedulingSnapshot {
        DiscoverySchedulingSnapshot(
            appState: .background, thermalState: thermal, batteryLevel: 0.9, isCharging: charging,
            isLowPowerModeEnabled: false, isPlaybackActive: false, isUserPaused: false,
            chargingOnlySetting: false, hasBackgroundProcessingGrant: grant, hasMemoryWarning: false,
            continuousNominalSeconds: 120)
    }

    private func foregroundSnapshot() -> DiscoverySchedulingSnapshot {
        DiscoverySchedulingSnapshot(
            appState: .foreground, thermalState: .nominal, batteryLevel: 0.9, isCharging: true,
            isLowPowerModeEnabled: false, isPlaybackActive: false, isUserPaused: false,
            chargingOnlySetting: false, hasBackgroundProcessingGrant: false, hasMemoryWarning: false,
            continuousNominalSeconds: 120)
    }

    private func writeSineWAV(seconds: Double, to url: URL) throws {
        let sr = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var remaining = Int((seconds * sr).rounded())
        var phase = 0.0
        let inc = 2.0 * Double.pi * 220.0 / sr
        while remaining > 0 {
            let n = min(Int(sr), remaining)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let ch = buf.floatChannelData![0]
            for i in 0..<n { ch[i] = Float(sin(phase) * 0.25); phase += inc }
            try file.write(from: buf)
            remaining -= n
        }
    }

    @discardableResult
    private func seedTrack(
        _ queue: DatabaseQueue, fileURL: URL?, durationSec: Double?
    ) async throws -> Int64 {
        try await queue.write { db in
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") == 0 {
                try db.execute(
                    sql: """
                        INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                            localIsFolder)
                        VALUES ('local', 'Music', ?, 0, 0, 1)
                        """, arguments: [Date()])
            }
            let sourceId = try Int64.fetchOne(db, sql: "SELECT id FROM source LIMIT 1")!
            var track = Track(
                id: nil, albumId: nil, sourceId: sourceId, title: "Song", trackNo: nil, discNo: nil,
                durationSec: durationSec, codec: "wav", sampleRate: 44_100, bitDepthOrBitrate: nil,
                sortKey: "song")
            try track.insert(db)
            if let fileURL {
                var asset = Asset(
                    id: nil, trackId: track.id!, kind: .localRef, bookmark: nil, relPath: nil,
                    remoteURL: fileURL.absoluteString, altRemoteURL: nil, sizeBytes: nil,
                    unsupportedReason: nil)
                try asset.insert(db)
            }
            return track.id!
        }
    }

    private func tmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeController(
        assembly: DiscoveryAssembly, scheduler: FakeScheduler, box: SnapshotBox,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> DiscoveryBackgroundController {
        let settings = await assembly.settings
        return DiscoveryBackgroundController(
            assembly: assembly, settings: settings, scheduler: scheduler,
            identifier: "test.discovery-index", earliestBeginInterval: 900, now: now,
            onBackgroundGrantChanged: { granted in
                box.mutate {
                    if granted { $0.appState = .background }
                    $0.hasBackgroundProcessingGrant = granted
                }
            })
    }

    private func checkpointCount(_ queue: DatabaseQueue) async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_window_checkpoint")!
        }
    }

    // MARK: - Registration

    func testRegistrationIsIdempotent() async throws {
        let queue = try makeQueue()
        let scheduler = FakeScheduler()
        let box = SnapshotBox(backgroundSnapshot())
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { box.snapshot() })
        let controller = await makeController(assembly: assembly, scheduler: scheduler, box: box)

        let first = await controller.register()
        let second = await controller.register()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(scheduler.registerCallCount, 1)
    }

    // MARK: - Submission / coalescing

    func testSubmitCoalescesToOneOutstandingRequest() async throws {
        let queue = try makeQueue()
        for _ in 0..<3 { _ = try await seedTrack(queue, fileURL: nil, durationSec: nil) }
        let scheduler = FakeScheduler()
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let box = SnapshotBox(backgroundSnapshot())
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { box.snapshot() })
        _ = try await assembly.recoverAndReconcileAtLaunch()  // bootstraps 3 queued jobs
        let controller = await makeController(
            assembly: assembly, scheduler: scheduler, box: box, now: { fixedNow })

        for _ in 0..<3 { await controller.submitPendingWorkRequestIfNeeded() }

        XCTAssertEqual(scheduler.pendingCount, 1, "same identifier coalesces to one request")
        let request = try XCTUnwrap(scheduler.lastRequest)
        XCTAssertTrue(request.requiresExternalPower)
        XCTAssertFalse(request.requiresNetworkConnectivity)
        XCTAssertEqual(request.earliestBeginDate, fixedNow.addingTimeInterval(900))

        let runtime = try await assembly.settings.runtime()
        XCTAssertEqual(runtime.lastBackgroundSubmissionResult, "submitted")
        XCTAssertEqual(runtime.lastBackgroundSubmissionAt, fixedNow)
        XCTAssertEqual(runtime.nextScheduledAt, fixedNow.addingTimeInterval(900))
    }

    func testNoRequestSubmittedWhenQueueIsEmpty() async throws {
        let queue = try makeQueue()
        let scheduler = FakeScheduler()
        let box = SnapshotBox(backgroundSnapshot())
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { box.snapshot() })
        let controller = await makeController(assembly: assembly, scheduler: scheduler, box: box)

        await controller.submitPendingWorkRequestIfNeeded()
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testSubmitFailureRecordedWithoutLosingJobs() async throws {
        let queue = try makeQueue()
        _ = try await seedTrack(queue, fileURL: nil, durationSec: nil)
        let scheduler = FakeScheduler()
        scheduler.shouldFailSubmit = true
        let box = SnapshotBox(backgroundSnapshot())
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { box.snapshot() })
        _ = try await assembly.recoverAndReconcileAtLaunch()
        let controller = await makeController(assembly: assembly, scheduler: scheduler, box: box)

        await controller.submitPendingWorkRequestIfNeeded()

        XCTAssertEqual(scheduler.pendingCount, 0)
        let runtime = try await assembly.settings.runtime()
        XCTAssertTrue(runtime.lastBackgroundSubmissionResult?.hasPrefix("error:") ?? false)
        let job = try await assembly.jobs.job(trackId: 1, pipelineVersion: 1)
        XCTAssertEqual(job?.state, .queued, "a failed submit must not lose the job")
    }

    // MARK: - Granted drain

    func testGrantedRunDrainsAndCompletesExactlyOnce() async throws {
        let queue = try makeQueue()
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<2 {
            let wav = dir.appendingPathComponent("s\(i).wav")
            try writeSineWAV(seconds: 12, to: wav)
            _ = try await seedTrack(queue, fileURL: wav, durationSec: 12)
        }
        let scheduler = FakeScheduler()
        let box = SnapshotBox(backgroundSnapshot())
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { box.snapshot() })
        await assembly.models.injectModelForTesting(DeterministicFakeSemanticModel(spec: spec()))
        _ = try await assembly.recoverAndReconcileAtLaunch()
        let controller = await makeController(assembly: assembly, scheduler: scheduler, box: box)
        _ = await controller.register()

        let invocation = FakeInvocation(identifier: "test.discovery-index")
        await controller.run(invocation)

        XCTAssertEqual(invocation.completeCount, 1, "BG task completed exactly once (plan §7)")
        XCTAssertEqual(invocation.lastSuccess, true)

        let embeddings = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_embedding")!
        }
        XCTAssertEqual(embeddings, 2)
        let runtime = try await assembly.settings.runtime()
        XCTAssertEqual(runtime.coverageSnapshot, "2 / 2")
        XCTAssertEqual(runtime.lastStopReason, "background: 2 completed")
        XCTAssertNotNil(runtime.lastSuccessfulWorkAt)
    }

    // MARK: - Expiration mid-drain

    func testExpirationMidDrainKeepsCheckpointsAndJobResumes() async throws {
        let queue = try makeQueue()
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("long.wav")
        try writeSineWAV(seconds: 35, to: wav)  // -> 4 embedding windows
        _ = try await seedTrack(queue, fileURL: wav, durationSec: 35)

        let scheduler = FakeScheduler()
        let box = SnapshotBox(backgroundSnapshot())
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { box.snapshot() })
        await assembly.models.injectModelForTesting(DeterministicFakeSemanticModel(spec: spec()))
        _ = try await assembly.recoverAndReconcileAtLaunch()
        let controller = await makeController(assembly: assembly, scheduler: scheduler, box: box)
        _ = await controller.register()

        let invocation = FakeInvocation(identifier: "test.discovery-index")
        // Fire expiration after a few windows have been persisted, but before
        // the job can finalize.
        box.onRead = { count, _ in
            if count == 4 { invocation.fireExpiration() }
        }
        await controller.run(invocation)

        XCTAssertEqual(invocation.completeCount, 1)
        XCTAssertEqual(invocation.lastSuccess, false, "expired run reports failure so iOS reschedules")

        let job = try await assembly.jobs.job(trackId: 1, pipelineVersion: 1)
        XCTAssertNotEqual(job?.state, .complete)
        XCTAssertEqual(job?.attemptCount, 0, "expiration is not a transient failure")
        let checkpoints = try await checkpointCount(queue)
        XCTAssertGreaterThanOrEqual(checkpoints, 1, "durable window checkpoints survived")
        XCTAssertLessThan(checkpoints, 4, "the job did not finish before expiry")

        let runtime = try await assembly.settings.runtime()
        XCTAssertTrue(runtime.lastStopReason?.contains("expired") ?? false)

        // Resume on the next (foreground) drain: it picks up at the next
        // missing window and completes.
        box.onRead = nil
        box.mutate { $0 = self.foregroundSnapshot() }
        let completed = try await assembly.drainQueue()
        XCTAssertEqual(completed, 1)
        let resumed = try await assembly.jobs.job(trackId: 1, pipelineVersion: 1)
        XCTAssertEqual(resumed?.state, .complete)
        let embeddings = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_embedding")!
        }
        XCTAssertEqual(embeddings, 1)
    }

    // MARK: - Grant revoked mid-run

    func testBackgroundGrantRevokedMidRunReleasesJobNoRetryPenalty() async throws {
        let queue = try makeQueue()
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("long.wav")
        try writeSineWAV(seconds: 35, to: wav)
        _ = try await seedTrack(queue, fileURL: wav, durationSec: 35)

        let scheduler = FakeScheduler()
        let box = SnapshotBox(backgroundSnapshot())
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { box.snapshot() })
        await assembly.models.injectModelForTesting(DeterministicFakeSemanticModel(spec: spec()))
        _ = try await assembly.recoverAndReconcileAtLaunch()
        let controller = await makeController(assembly: assembly, scheduler: scheduler, box: box)

        box.onRead = { count, b in
            if count == 3 { b.mutate { $0.hasBackgroundProcessingGrant = false } }
        }
        let invocation = FakeInvocation(identifier: "test.discovery-index")
        await controller.run(invocation)

        XCTAssertEqual(invocation.completeCount, 1)
        let job = try await assembly.jobs.job(trackId: 1, pipelineVersion: 1)
        XCTAssertEqual(job?.state, .queued, "grant loss releases the job, not a waiting state")
        XCTAssertEqual(job?.attemptCount, 0)
        let checkpoints = try await checkpointCount(queue)
        XCTAssertGreaterThanOrEqual(checkpoints, 1)
    }

    // MARK: - Power / thermal transitions mid-run

    func testChargingLostMidRunParksJobWaitingForPower() async throws {
        let queue = try makeQueue()
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("long.wav")
        try writeSineWAV(seconds: 35, to: wav)
        _ = try await seedTrack(queue, fileURL: wav, durationSec: 35)

        let scheduler = FakeScheduler()
        let box = SnapshotBox(backgroundSnapshot())
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { box.snapshot() })
        await assembly.models.injectModelForTesting(DeterministicFakeSemanticModel(spec: spec()))
        _ = try await assembly.recoverAndReconcileAtLaunch()
        let controller = await makeController(assembly: assembly, scheduler: scheduler, box: box)

        box.onRead = { count, b in
            if count == 3 { b.mutate { $0.isCharging = false } }
        }
        await controller.run(FakeInvocation(identifier: "test.discovery-index"))

        let job = try await assembly.jobs.job(trackId: 1, pipelineVersion: 1)
        XCTAssertEqual(job?.state, .waitingForPower)
        XCTAssertEqual(job?.attemptCount, 0)
    }

    func testThermalSeriousMidRunParksJobWaitingForCooling() async throws {
        let queue = try makeQueue()
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("long.wav")
        try writeSineWAV(seconds: 35, to: wav)
        _ = try await seedTrack(queue, fileURL: wav, durationSec: 35)

        let scheduler = FakeScheduler()
        let box = SnapshotBox(backgroundSnapshot())
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { box.snapshot() })
        await assembly.models.injectModelForTesting(DeterministicFakeSemanticModel(spec: spec()))
        _ = try await assembly.recoverAndReconcileAtLaunch()
        let controller = await makeController(assembly: assembly, scheduler: scheduler, box: box)

        box.onRead = { count, b in
            if count == 3 { b.mutate { $0.thermalState = .serious } }
        }
        await controller.run(FakeInvocation(identifier: "test.discovery-index"))

        let job = try await assembly.jobs.job(trackId: 1, pipelineVersion: 1)
        XCTAssertEqual(job?.state, .waitingForCooling)
        XCTAssertEqual(job?.attemptCount, 0)
    }
}
#endif
