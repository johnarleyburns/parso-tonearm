#if !os(watchOS)
import AVFoundation
import Foundation
import GRDB
import Testing

@testable import TonearmCore
@testable import TonearmDiscovery

/// End-to-end fixtures for the musical-analysis worker: the real
/// `BoundedIndexWorker` driven through `IndexScheduler`, against real audio
/// fixtures generated on disk. Covers the bounded-read/analysis path,
/// corrupt-audio handling, content replacement, and asset selection.
@Suite struct BoundedIndexWorkerTests {
    // MARK: - Harness

    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
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
        let chunkFrames = AVAudioFrameCount(sampleRate)
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

    /// Write a real mono WAV of `seconds` at 44.1 kHz containing decaying kick impulses on a
    /// fixed beat grid — a genuine decodable fixture the real tempo/beat tracker should find a
    /// bpm in, unlike `writeSineWAV`'s flat tone.
    private func writeClickWAV(bpm: Double, seconds: Double, to url: URL) throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let totalFrames = Int((seconds * sampleRate).rounded())
        let periodFrames = Int((60.0 / bpm * sampleRate).rounded())
        let kickFrames = Int(0.05 * sampleRate)
        let chunkFrames = AVAudioFrameCount(sampleRate)
        var written = 0
        while written < totalFrames {
            let n = min(Int(chunkFrames), totalFrames - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            let ch = buffer.floatChannelData![0]
            for i in 0..<n {
                let phaseInPeriod = (written + i) % periodFrames
                if phaseInPeriod < kickFrames {
                    let envelope = Float(exp(-Double(phaseInPeriod) / Double(kickFrames) * 5.0))
                    ch[i] = 0.9 * envelope * Float(sin(2.0 * Double.pi * 80.0 * Double(phaseInPeriod) / sampleRate))
                } else {
                    ch[i] = 0
                }
            }
            try file.write(from: buffer)
            written += n
        }
    }

    /// A real rhythmic fixture gets a real bpm through the full worker, and no
    /// `discovery_transition_profile` write is ever attempted (the table no
    /// longer exists — see `MigrationV43Tests`).
    @Test func testMusicalAnalysisWritesRealBPMViaLeanAnalysisAndNeverTouchesTransitionProfile() async throws {
        let queue = try makeQueue()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("click.wav")
        let duration = 20.0
        try writeClickWAV(bpm: 128, seconds: duration, to: wav)

        let (trackId, assetId) = try await seedTrackWithAsset(queue, fileURL: wav, durationSec: duration)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: assetId, assetRevision: 1, pipelineVersion: 1)
        let scheduler = IndexScheduler(jobs: jobs, worker: BoundedIndexWorker(writer: queue))

        let outcome = try await runToCompletion(scheduler)
        guard case .jobCompleted = outcome else {
            Issue.record("expected jobCompleted, got \(outcome)")
            return
        }

        let analysis = try await queue.read { db in try DiscoveryTrackAnalysis.fetchOne(db, key: trackId) }
        let foundAnalysis = try #require(analysis)
        let bpm = try #require(foundAnalysis.bpm, "LeanAnalysis should find a real bpm")
        #expect(abs(bpm - 128) <= 2)

        let hasTable = try await queue.read { db in try db.tableExists("discovery_transition_profile") }
        #expect(!hasTable)
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

    /// End-to-end: one analysis read → `discovery_track_analysis` +
    /// `discovery_asset_state`, with no semantic tables or `track.indexed`
    /// column left in the schema.
    @Test func testEndToEndPopulatesAnalysisAndAssetStateRows() async throws {
        let queue = try makeQueue()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("song.wav")
        try writeSineWAV(seconds: 35, to: wav)

        let (trackId, assetId) = try await seedTrackWithAsset(
            queue, fileURL: wav, durationSec: 35)
        let jobs = IndexJobRepository(writer: queue)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: assetId, assetRevision: 1, pipelineVersion: 1)
        let scheduler = IndexScheduler(jobs: jobs, worker: BoundedIndexWorker(writer: queue))

        let outcome = try await runToCompletion(scheduler)
        guard case .jobCompleted = outcome else {
            let j = try await jobs.job(trackId: trackId, pipelineVersion: 1)
            Issue.record(
                "expected jobCompleted, got \(outcome); errorCode=\(j?.errorCode ?? "nil") msg=\(j?.errorMessage ?? "nil") mus=\(j?.musicalAnalysisStageState.rawValue ?? "?")")
            return
        }

        let (analysis, assetState) = try await queue.read {
            db -> (DiscoveryTrackAnalysis?, DiscoveryAssetState?) in
            (
                try DiscoveryTrackAnalysis.fetchOne(db, key: trackId),
                try DiscoveryAssetState.fetchOne(db, key: assetId)
            )
        }

        let ana = try #require(analysis)
        #expect(ana.analysisVersion == DiscoveryPipelineVersion.musicalAnalysis)
        #expect(ana.completedAt != nil)
        let analysisScopeSeconds = try #require(ana.analysisScopeSeconds)
        #expect(abs(analysisScopeSeconds - 35) <= 0.5, "shorter file analyzed in full")

        let state = try #require(assetState)
        #expect(state.observedSizeBytes == Int64((try Data(contentsOf: wav)).count))
        #expect(state.observedMTime != nil)

        let (hasEmbedding, hasCheckpoints, hasEmbeddingSpace, hasIndexedColumn) = try await queue.read { db in
            (
                try db.tableExists("discovery_embedding"),
                try db.tableExists("discovery_window_checkpoint"),
                try db.tableExists("discovery_embedding_space"),
                try db.columns(in: "track").contains { $0.name == "indexed" }
            )
        }
        #expect(!hasEmbedding)
        #expect(!hasCheckpoints)
        #expect(!hasEmbeddingSpace)
        #expect(!hasIndexedColumn)

        let coverage = try await jobs.coverage(pipelineVersion: 1)
        #expect(coverage.complete == 1)
        #expect(coverage.failed == 0)
    }

    /// A short track (<= 10 s) is analyzed in full and still completes.
    @Test func testShortTrackCompletesWithFullScope() async throws {
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
        let scheduler = IndexScheduler(jobs: jobs, worker: BoundedIndexWorker(writer: queue))

        _ = try await runToCompletion(scheduler)
        let analysis = try await queue.read { db in try DiscoveryTrackAnalysis.fetchOne(db, key: trackId) }
        let ana = try #require(analysis)
        #expect(abs((ana.analysisScopeSeconds ?? 0) - 4) <= 0.5)
    }

    /// Corrupt/unsupported audio must terminate the stage explicitly — never
    /// an infinite retry or a fabricated analysis row (plan §6/§8/§11).
    @Test func testCorruptAudioTerminatesUnsupported() async throws {
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
        let scheduler = IndexScheduler(jobs: jobs, worker: BoundedIndexWorker(writer: queue))

        _ = try await runToCompletion(scheduler)

        let job = try #require(try await jobs.job(trackId: trackId, pipelineVersion: 1))
        #expect(job.musicalAnalysisStageState == .unsupported)
        let analysis = try await queue.read { db in
            try DiscoveryTrackAnalysis.fetchOne(db, key: trackId)
        }
        #expect(analysis == nil, "no fabricated analysis for undecodable audio")
        let coverage = try await jobs.coverage(pipelineVersion: 1)
        #expect(coverage.failed == 1)
    }

    /// A content replacement (`restart: true`) re-analyzes against the new
    /// revision rather than preserving stale BPM/key facts.
    @Test func testContentReplacementReanalyzes() async throws {
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
        let scheduler = IndexScheduler(jobs: jobs, worker: BoundedIndexWorker(writer: queue))

        _ = try await runToCompletion(scheduler)
        let first = try #require(
            try await queue.read { db in try DiscoveryTrackAnalysis.fetchOne(db, key: trackId) })
        #expect(first.assetRevision == 1)

        try writeSineWAV(seconds: 22, to: wav)
        try await jobs.enqueueOrRestart(
            trackId: trackId, selectedAssetId: assetId, assetRevision: 2, pipelineVersion: 1,
            restart: true)

        _ = try await runToCompletion(scheduler)
        let second = try #require(
            try await queue.read { db in try DiscoveryTrackAnalysis.fetchOne(db, key: trackId) })
        #expect(second.assetRevision == 2)
        #expect(second.completedAt != nil)
    }

    /// Deterministic preferred-asset selection (plan §5): a valid local
    /// original outranks a remote downloadable original regardless of id
    /// order; ties break by ascending id.
    @Test func testPreferredAssetSelectionOrder() throws {
        let local = Asset(
            id: 9, trackId: 1, kind: .localRef, bookmark: Data([1, 2, 3]), relPath: nil,
            remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        let remote = Asset(
            id: 2, trackId: 1, kind: .remote, bookmark: nil, relPath: nil,
            remoteURL: "https://example.com/a.flac", altRemoteURL: nil, sizeBytes: nil,
            unsupportedReason: nil)
        #expect(DiscoveryReconciler.preferredAsset(from: [remote, local])?.id == 9)

        let localA = Asset(
            id: 7, trackId: 1, kind: .managedCopy, bookmark: nil, relPath: "a.caf", remoteURL: nil,
            altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        let localB = Asset(
            id: 3, trackId: 1, kind: .localRef, bookmark: nil, relPath: "b.caf", remoteURL: nil,
            altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        #expect(DiscoveryReconciler.preferredAsset(from: [localA, localB])?.id == 3)

        let unsupported = Asset(
            id: 1, trackId: 1, kind: .localRef, bookmark: Data([9]), relPath: nil, remoteURL: nil,
            altRemoteURL: nil, sizeBytes: nil, unsupportedReason: "drm")
        #expect(
            DiscoveryReconciler.preferredAsset(from: [unsupported, remote]) == nil,
            "neither an unsupported nor a remote-only asset is a valid pick")
    }
}
#endif
