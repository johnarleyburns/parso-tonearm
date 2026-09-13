#if !os(watchOS)
import AVFoundation
import GRDB
import ParsoAudioNeural
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// C04/C05 seam: the app-owned `DiscoveryAssembly` graph — one repository/
/// reconciler/scheduler/model set over the single core writer — recovers at
/// launch and drains the queue end to end against a deterministic synthetic
/// encoder and real on-disk audio.
final class DiscoveryAssemblyTests: XCTestCase {
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

    private func nominal(paused: Bool = false) -> DiscoverySchedulingSnapshot {
        DiscoverySchedulingSnapshot(
            appState: .foreground, thermalState: .nominal, batteryLevel: 0.9, isCharging: true,
            isLowPowerModeEnabled: false, isPlaybackActive: false, isUserPaused: paused,
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

    func testRecoverAndReconcileResetsStaleLeasesAndBootstrapsAllTracks() async throws {
        let queue = try makeQueue()
        for _ in 0..<3 { _ = try await seedTrack(queue, fileURL: nil, durationSec: nil) }

        // A job left "running" with an expired lease by a prior process.
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: 1, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)
        _ = try await jobs.claimNextJob(leaseDuration: -1)

        let snap = nominal()
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { snap })
        let recovery = try await assembly.recoverAndReconcileAtLaunch()

        XCTAssertEqual(recovery.resetIndexLeases, 1)
        XCTAssertEqual(recovery.bootstrappedTracks, 2, "tracks 2 and 3 had no job yet")
        let coverage = try await jobs.coverage(pipelineVersion: 1)
        XCTAssertEqual(coverage.total, 3)
    }

    func testDrainQueueRunsBootstrappedJobsToCompletion() async throws {
        let queue = try makeQueue()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var trackIds: [Int64] = []
        for i in 0..<2 {
            let wav = dir.appendingPathComponent("s\(i).wav")
            try writeSineWAV(seconds: 14, to: wav)
            trackIds.append(try await seedTrack(queue, fileURL: wav, durationSec: 14))
        }

        let snap = nominal()
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { snap })
        await assembly.models.injectModelForTesting(DeterministicFakeSemanticModel(spec: spec()))
        _ = try await assembly.recoverAndReconcileAtLaunch()

        let completed = try await assembly.drainQueue()
        XCTAssertEqual(completed, 2)

        let embeddingCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_embedding")!
        }
        XCTAssertEqual(embeddingCount, 2)
        let coverage = try await assembly.jobs.coverage(pipelineVersion: 1)
        XCTAssertEqual(coverage.complete, 2)
    }

    func testDrainQueueDoesNothingWhileUserPaused() async throws {
        let queue = try makeQueue()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("s.wav")
        try writeSineWAV(seconds: 5, to: wav)
        _ = try await seedTrack(queue, fileURL: wav, durationSec: 5)

        let snap = nominal(paused: true)
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { snap })
        await assembly.models.injectModelForTesting(DeterministicFakeSemanticModel(spec: spec()))
        _ = try await assembly.recoverAndReconcileAtLaunch()

        let completed = try await assembly.drainQueue()
        XCTAssertEqual(completed, 0)
        let job = try await assembly.jobs.job(trackId: 1, pipelineVersion: 1)
        XCTAssertEqual(job?.state, .queued, "paused leaves the job untouched")
    }

    /// Reproduces the real TestFlight report: a pre-existing library (tracks
    /// already in `LibraryStore` before Discovery ever ran — exactly an
    /// app-update scenario, not a fresh import) goes through the real launch
    /// sequence (`recoverAndReconcileAtLaunch`, then repeated `drainQueue`
    /// ticks, exactly like `DiscoveryRuntimeController`'s foreground loop),
    /// but the scheduler is persistently gated by a real `IndexPolicy`
    /// condition (thermal, here — any of thermalSerious/critical/fair,
    /// low battery, playback, missing background grant reproduce the same
    /// thing). Before the fix, `coverage.queuedOrRunning == total` with
    /// `complete == 0` forever and `lastBlockReason` did not exist, so
    /// `IndexStatusPresentation` had no way to distinguish this from real
    /// progress — see `IndexStatusPresentationTests
    /// .testBlockedSchedulerNeverShownAsGenericIndexing` for the UI half of
    /// this regression.
    func testPersistentPolicyBlockLeavesJobsQueuedAndRecordsTheRealReason() async throws {
        let queue = try makeQueue()
        let trackCount = 25
        for _ in 0..<trackCount { _ = try await seedTrack(queue, fileURL: nil, durationSec: nil) }

        // Real-world gate: device thermal state has not been continuously
        // nominal for the 60s `IndexPolicy.thermalFairRecoverySeconds`
        // requirement — exactly the state a phone can sit in for minutes if
        // thermal is flapping right after a big TestFlight install.
        final class SnapshotBox: @unchecked Sendable {
            var value: DiscoverySchedulingSnapshot
            init(_ v: DiscoverySchedulingSnapshot) { value = v }
        }
        let box = SnapshotBox(
            DiscoverySchedulingSnapshot(
                appState: .foreground, thermalState: .nominal, batteryLevel: 0.9, isCharging: true,
                isLowPowerModeEnabled: false, isPlaybackActive: false, isUserPaused: false,
                chargingOnlySetting: false, hasBackgroundProcessingGrant: false,
                hasMemoryWarning: false, continuousNominalSeconds: 5))
        let assembly = DiscoveryAssembly(writer: queue, snapshotProvider: { box.value })
        await assembly.models.injectModelForTesting(DeterministicFakeSemanticModel(spec: spec()))

        let recovery = try await assembly.recoverAndReconcileAtLaunch()
        XCTAssertEqual(recovery.bootstrappedTracks, trackCount, "every pre-existing track got a job")

        // Simulate several foreground tick-loop passes (the real loop calls
        // drainQueue every 20s) — none of them should make progress while
        // the gate holds, and the loop must not lose the reason.
        for _ in 0..<5 {
            let completed = try await assembly.drainQueue()
            XCTAssertEqual(completed, 0)
        }

        let coverage = try await assembly.jobs.coverage(pipelineVersion: 1)
        XCTAssertEqual(coverage.total, trackCount)
        XCTAssertEqual(coverage.complete, 0)
        XCTAssertEqual(
            coverage.queuedOrRunning, trackCount,
            "jobs blocked before being claimed stay .queued — this is what made the old "
                + "status UI show a generic, unexplained 'Indexing' forever")
        let reasonAfterBlock = await assembly.lastBlockReason
        XCTAssertEqual(reasonAfterBlock, .thermalFair)

        let snapshot = try await assembly.statusSnapshot()
        XCTAssertEqual(snapshot.schedulerBlockReason, .thermalFair)

        // Once the real condition clears, the scheduler is unblocked and the
        // stale reason must not survive — even though these particular jobs
        // (no local audio asset seeded) will simply move on to a different
        // wait state rather than completing.
        box.value = DiscoverySchedulingSnapshot(
            appState: .foreground, thermalState: .nominal, batteryLevel: 0.9, isCharging: true,
            isLowPowerModeEnabled: false, isPlaybackActive: false, isUserPaused: false,
            chargingOnlySetting: false, hasBackgroundProcessingGrant: false,
            hasMemoryWarning: false, continuousNominalSeconds: 120)
        _ = try await assembly.drainQueue()
        let reasonAfterRecovery = await assembly.lastBlockReason
        XCTAssertNil(reasonAfterRecovery, "a resolved gate must not leave a stale reason behind")
    }
}
#endif
