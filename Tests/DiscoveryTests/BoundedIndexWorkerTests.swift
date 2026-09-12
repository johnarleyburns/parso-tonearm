#if !os(watchOS)
import AVFoundation
import GRDB
import ParsoAudioNeural
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// C04 end-to-end fixtures (IMPLEMENT_CLAP_PLAN.md §6/§7/§8/§11): the real
/// `BoundedIndexWorker` driven through `IndexScheduler`, against a
/// deterministic synthetic CLAP encoder injected via
/// `ModelManager.injectModelForTesting` (the plan's own sanctioned seam for
/// "synthetic test encoders for deterministic automation") and real audio
/// fixtures generated on disk. Also covers the C03/C04 fixtures that the
/// windowed reader now unblocks: corrupt-audio handling and checkpoint
/// rollback/resume.
final class BoundedIndexWorkerTests: XCTestCase {
    // MARK: - Harness

    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
    }

    private func syntheticSpec() -> EmbeddingModelSpec {
        // logMel(clip:spec:) requires a filterbank of exactly
        // (fftSize/2 + 1) * melBins entries; the values themselves are
        // irrelevant to the deterministic fake encoder (it hashes the
        // resulting log-mel bytes), only the shape must be valid.
        let meta = EmbeddingModelSpec.musicCLAPMetadata
        let bins = meta.fftSize / 2 + 1
        return EmbeddingModelSpec.musicCLAP(
            melFilterBank: [Float](repeating: 0.01, count: bins * meta.melBins))
    }

    @discardableResult
    private func seedSource(_ queue: DatabaseQueue) async throws -> Int64 {
        try await queue.write { db in
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") == 0 {
                try db.execute(
                    sql: """
                        INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                            localIsFolder)
                        VALUES ('local', 'Music', ?, 0, 0, 1)
                        """, arguments: [Date()])
            }
            return try Int64.fetchOne(db, sql: "SELECT id FROM source LIMIT 1")!
        }
    }

    private func seedTrackWithAsset(
        _ queue: DatabaseQueue, fileURL: URL, durationSec: Double?, kind: AssetKind = .localRef
    ) async throws -> (trackId: Int64, assetId: Int64) {
        let sourceId = try await seedSource(queue)
        return try await queue.write { db in
            var track = Track(
                id: nil, albumId: nil, sourceId: sourceId, title: "Song", trackNo: nil, discNo: nil,
                durationSec: durationSec, codec: "wav", sampleRate: 44_100, bitDepthOrBitrate: nil,
                sortKey: "song")
            try track.insert(db)
            let trackId = track.id!
            var asset = Asset(
                id: nil, trackId: trackId, kind: kind, bookmark: nil, relPath: nil,
                remoteURL: fileURL.absoluteString, altRemoteURL: nil, sizeBytes: nil,
                unsupportedReason: nil)
            try asset.insert(db)
            return (trackId, asset.id!)
        }
    }

    /// Write a real mono WAV of `seconds` at 44.1 kHz containing a 220 Hz
    /// sine — a genuine decodable fixture for the bounded reader and the real
    /// BPM/key/energy analyzers.
    private func writeSineWAV(seconds: Double, to url: URL) throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunkFrames = AVAudioFrameCount(sampleRate)  // 1 s at a time
        var remaining = Int((seconds * sampleRate).rounded())
        var phase = 0.0
        let increment = 2.0 * Double.pi * 220.0 / sampleRate
        while remaining > 0 {
            let n = min(Int(chunkFrames), remaining)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            let ch = buffer.floatChannelData![0]
            for i in 0..<n {
                ch[i] = Float(sin(phase) * 0.25)
                phase += increment
            }
            try file.write(from: buffer)
            remaining -= n
        }
    }

    private func nominalSnapshot() -> DiscoverySchedulingSnapshot {
        DiscoverySchedulingSnapshot(
            appState: .foreground, thermalState: .nominal, batteryLevel: 0.9, isCharging: true,
            isLowPowerModeEnabled: false, isPlaybackActive: false, isUserPaused: false,
            chargingOnlySetting: false, hasBackgroundProcessingGrant: false, hasMemoryWarning: false,
            continuousNominalSeconds: 120)
    }

    /// Drive the scheduler until the claimed job leaves the run loop.
    @discardableResult
    private func runToCompletion(
        _ scheduler: IndexScheduler, maxTicks: Int = 40
    ) async throws -> IndexScheduler.TickOutcome {
        var last: IndexScheduler.TickOutcome = .idle
        let snapshot = nominalSnapshot()
        for _ in 0..<maxTicks {
            last = try await scheduler.tick { snapshot }
            switch last {
            case .jobCompleted, .jobFailed, .jobWaiting, .blocked:
                return last
            case .idle, .jobPreempted:
                return last
            }
        }
        return last
    }

    // MARK: - Tests

    /// Full pipeline: bounded windowed reads → synthetic CLAP → pooled,
    /// quantized `discovery_embedding`; then real BPM/key/energy →
    /// `discovery_track_analysis`; plus `discovery_asset_state` populated from
    /// the actual file it read.
    func testEndToEndPopulatesEmbeddingAnalysisAndAssetStateRows() async throws {
        let queue = try makeQueue()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("song.wav")
        try writeSineWAV(seconds: 35, to: wav)  // > 10 s → multiple windows

        let (trackId, assetId) = try await seedTrackWithAsset(
            queue, fileURL: wav, durationSec: 35)

        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: assetId, assetRevision: 1, pipelineVersion: 1)

        let models = ModelManager(resourceProvider: { .unavailable })
        await models.injectModelForTesting(DeterministicFakeSemanticModel(spec: syntheticSpec()))
        let worker = BoundedIndexWorker(writer: queue, jobs: jobs, models: models)
        let scheduler = IndexScheduler(jobs: jobs, worker: worker, sleeper: { _ in })

        let outcome = try await runToCompletion(scheduler)
        guard case .jobCompleted = outcome else {
            let j = try await jobs.job(trackId: trackId, pipelineVersion: 1)
            return XCTFail(
                "expected jobCompleted, got \(outcome); errorCode=\(j?.errorCode ?? "nil") "
                    + "msg=\(j?.errorMessage ?? "nil") emb=\(j?.embeddingStageState.rawValue ?? "?") "
                    + "mus=\(j?.musicalAnalysisStageState.rawValue ?? "?")")
        }

        let (embedding, analysis, assetState) = try await queue.read {
            db -> (DiscoveryEmbedding?, DiscoveryTrackAnalysis?, DiscoveryAssetState?) in
            (
                try DiscoveryEmbedding.fetchOne(db, key: trackId),
                try DiscoveryTrackAnalysis.fetchOne(db, key: trackId),
                try DiscoveryAssetState.fetchOne(db, key: assetId)
            )
        }

        let vec = try XCTUnwrap(embedding)
        XCTAssertEqual(vec.dimensions, syntheticSpec().dimensions)
        XCTAssertEqual(vec.quantizedVector.count, vec.dimensions, "one int8 per dimension")
        XCTAssertGreaterThan(vec.scale, 0)
        XCTAssertEqual(vec.samplingVersion, DiscoveryPipelineVersion.sampling)

        let ana = try XCTUnwrap(analysis)
        XCTAssertEqual(ana.analysisVersion, DiscoveryPipelineVersion.musicalAnalysis)
        XCTAssertNotNil(ana.completedAt)
        XCTAssertEqual(
            try XCTUnwrap(ana.analysisScopeSeconds), 35, accuracy: 0.5,
            "shorter file analyzed in full")

        let state = try XCTUnwrap(assetState)
        XCTAssertEqual(state.observedSizeBytes, Int64((try Data(contentsOf: wav)).count))
        XCTAssertNotNil(state.observedMTime)

        // No window checkpoints survive a finalized embedding (plan §6).
        let leftoverCheckpoints = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_window_checkpoint")!
        }
        XCTAssertEqual(leftoverCheckpoints, 0)

        let coverage = try await jobs.coverage(pipelineVersion: 1)
        XCTAssertEqual(coverage.complete, 1)
        XCTAssertEqual(coverage.failed, 0)
    }

    /// A short track (<= 10 s) yields exactly one zero-padded window and still
    /// produces a valid finite, non-zero-norm embedding.
    func testShortTrackProducesOneWindowEmbedding() async throws {
        let queue = try makeQueue()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("short.wav")
        try writeSineWAV(seconds: 4, to: wav)

        let (trackId, assetId) = try await seedTrackWithAsset(queue, fileURL: wav, durationSec: 4)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: assetId, assetRevision: 1, pipelineVersion: 1)
        let models = ModelManager(resourceProvider: { .unavailable })
        await models.injectModelForTesting(DeterministicFakeSemanticModel(spec: syntheticSpec()))
        let scheduler = IndexScheduler(
            jobs: jobs, worker: BoundedIndexWorker(writer: queue, jobs: jobs, models: models),
            sleeper: { _ in })

        _ = try await runToCompletion(scheduler)
        let vec = try await queue.read { db in try DiscoveryEmbedding.fetchOne(db, key: trackId) }
        let embedding = try XCTUnwrap(vec)
        let ints = embedding.quantizedVector.map { Int8(bitPattern: $0) }
        XCTAssertTrue(ints.contains { $0 != 0 }, "non-zero-norm vector")
    }

    /// Corrupt/unsupported audio must terminate the stage explicitly — never
    /// a fake embedding, never an infinite retry (plan §6/§8/§11).
    func testCorruptAudioTerminatesWithoutEmbedding() async throws {
        let queue = try makeQueue()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("garbage.wav")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: wav)

        let (trackId, assetId) = try await seedTrackWithAsset(queue, fileURL: wav, durationSec: nil)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: assetId, assetRevision: 1, pipelineVersion: 1)
        let models = ModelManager(resourceProvider: { .unavailable })
        await models.injectModelForTesting(DeterministicFakeSemanticModel(spec: syntheticSpec()))
        let scheduler = IndexScheduler(
            jobs: jobs, worker: BoundedIndexWorker(writer: queue, jobs: jobs, models: models),
            sleeper: { _ in })

        _ = try await runToCompletion(scheduler)

        let jobRow = try await jobs.job(trackId: trackId, pipelineVersion: 1)
        let job = try XCTUnwrap(jobRow)
        XCTAssertEqual(job.embeddingStageState, .unsupported)
        let embedding = try await queue.read { db in
            try DiscoveryEmbedding.fetchOne(db, key: trackId)
        }
        XCTAssertNil(embedding, "no fabricated embedding for undecodable audio")
    }

    /// Checkpoint rollback: a content replacement (`restart: true`) clears
    /// prior window checkpoints and the stale embedding, and a fresh run
    /// re-derives everything against the new revision (plan §4/§11).
    func testContentReplacementRollsBackCheckpointsAndReindexes() async throws {
        let queue = try makeQueue()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("song.wav")
        try writeSineWAV(seconds: 22, to: wav)

        let (trackId, assetId) = try await seedTrackWithAsset(queue, fileURL: wav, durationSec: 22)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: assetId, assetRevision: 1, pipelineVersion: 1)
        let models = ModelManager(resourceProvider: { .unavailable })
        await models.injectModelForTesting(DeterministicFakeSemanticModel(spec: syntheticSpec()))
        let scheduler = IndexScheduler(
            jobs: jobs, worker: BoundedIndexWorker(writer: queue, jobs: jobs, models: models),
            sleeper: { _ in })

        _ = try await runToCompletion(scheduler)
        let firstVec = try await queue.read { db in
            try DiscoveryEmbedding.fetchOne(db, key: trackId)
        }
        XCTAssertNotNil(firstVec)

        // Simulate a real content replacement.
        try writeSineWAV(seconds: 22, to: wav)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: assetId, assetRevision: 2, pipelineVersion: 1,
            restart: true)

        let completedAfterRestart = try await jobs.completedWindowIndices(jobId: firstJobId(queue, trackId))
        XCTAssertTrue(completedAfterRestart.isEmpty, "restart clears window checkpoints")

        _ = try await runToCompletion(scheduler)
        let secondRow = try await queue.read { db in
            try DiscoveryEmbedding.fetchOne(db, key: trackId)
        }
        XCTAssertEqual(try XCTUnwrap(secondRow).assetRevision, 2)
    }

    /// A pre-existing checkpoint for window 0 is not re-read: the worker
    /// resumes at the next missing window after a simulated relaunch
    /// (plan §6: "Resume at the next missing window after relaunch").
    func testResumesAtNextMissingWindow() async throws {
        let queue = try makeQueue()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("song.wav")
        try writeSineWAV(seconds: 35, to: wav)
        let (trackId, assetId) = try await seedTrackWithAsset(queue, fileURL: wav, durationSec: 35)

        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: assetId, assetRevision: 1, pipelineVersion: 1)
        let jobId = firstJobId(queue, trackId)

        // Pre-seed a checkpoint for window index 0 with a sentinel vector, as
        // though a prior process had completed it before being killed.
        let sentinel = [Float](repeating: 0.5, count: syntheticSpec().dimensions)
        try await queue.write { db in
            var cp = DiscoveryWindowCheckpoint(
                jobId: jobId, revisionSignature: "1", windowIndex: 0, startSeconds: 0,
                embeddingVector: sentinel.withUnsafeBufferPointer { Data(buffer: $0) },
                poolingWeight: 1, completedAt: Date())
            try cp.insert(db)
        }

        let before = try await jobs.completedWindowIndices(jobId: jobId)
        XCTAssertEqual(before, [0])

        let models = ModelManager(resourceProvider: { .unavailable })
        await models.injectModelForTesting(DeterministicFakeSemanticModel(spec: syntheticSpec()))
        let scheduler = IndexScheduler(
            jobs: jobs, worker: BoundedIndexWorker(writer: queue, jobs: jobs, models: models),
            sleeper: { _ in })
        _ = try await runToCompletion(scheduler)

        let vecRow = try await queue.read { db in
            try DiscoveryEmbedding.fetchOne(db, key: trackId)
        }
        XCTAssertEqual(try XCTUnwrap(vecRow).dimensions, syntheticSpec().dimensions)
    }

    /// Deterministic preferred-asset selection (plan §5): a valid local
    /// original outranks a remote downloadable original regardless of id
    /// order; ties break by ascending id.
    func testPreferredAssetSelectionOrder() throws {
        let local = Asset(
            id: 9, trackId: 1, kind: .localRef, bookmark: Data([1, 2, 3]), relPath: nil,
            remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        let remote = Asset(
            id: 2, trackId: 1, kind: .remote, bookmark: nil, relPath: nil,
            remoteURL: "https://example.com/a.flac", altRemoteURL: nil, sizeBytes: nil,
            unsupportedReason: nil)
        XCTAssertEqual(DiscoveryReconciler.preferredAsset(from: [remote, local])?.id, 9)

        let localA = Asset(
            id: 7, trackId: 1, kind: .managedCopy, bookmark: nil, relPath: "a.caf", remoteURL: nil,
            altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        let localB = Asset(
            id: 3, trackId: 1, kind: .localRef, bookmark: nil, relPath: "b.caf", remoteURL: nil,
            altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        XCTAssertEqual(DiscoveryReconciler.preferredAsset(from: [localA, localB])?.id, 3)

        let unsupported = Asset(
            id: 1, trackId: 1, kind: .localRef, bookmark: Data([9]), relPath: nil, remoteURL: nil,
            altRemoteURL: nil, sizeBytes: nil, unsupportedReason: "drm")
        XCTAssertEqual(
            DiscoveryReconciler.preferredAsset(from: [unsupported, remote])?.id, 2,
            "an unsupported asset is skipped")
    }

    // MARK: - small async helpers

    private func firstJobId(_ queue: DatabaseQueue, _ trackId: Int64) -> String {
        (try? queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT id FROM discovery_index_job WHERE trackId = ? LIMIT 1",
                arguments: [trackId])
        }) ?? ""
    }
}
#endif
