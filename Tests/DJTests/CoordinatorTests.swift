import XCTest
import GRDB
import TonearmCore

@testable import TonearmDJ

/// Coordinator + pipeline tests (§19): resume, idempotence, single-transaction
/// persist, version reconcile, and byte-determinism (NFR-DET-3). Uses tiny
/// synthetic WAVs so decode is real but fast.
final class CoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makePool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tonearm-dj.sqlite")
        let pool = try DJDatabase.open(at: url)
        return (pool, dir)
    }

    /// Writes a tiny mono 16-bit PCM WAV whose samples are a 440 Hz tone.
    private func makeToneWAV(at url: URL, seconds: Double = 0.5, amplitude: Float = 0.5) throws {
        var sampleRate: UInt32 = 48_000
        let frames = Int(seconds * 48_000)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        var size = UInt32(36 + frames * 2)
        data.append(Data(bytes: &size, count: 4))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        var fmtSize = UInt32(16); data.append(Data(bytes: &fmtSize, count: 4))
        var pcm: UInt16 = 1; data.append(Data(bytes: &pcm, count: 2))
        var mono: UInt16 = 1; data.append(Data(bytes: &mono, count: 2))
        data.append(Data(bytes: &sampleRate, count: 4))
        var byteRate = sampleRate * 2; data.append(Data(bytes: &byteRate, count: 4))
        var align: UInt16 = 2; data.append(Data(bytes: &align, count: 2))
        var bits: UInt16 = 16; data.append(Data(bytes: &bits, count: 2))
        data.append(contentsOf: Array("data".utf8))
        var dataSize = UInt32(frames * 2); data.append(Data(bytes: &dataSize, count: 4))
        for i in 0..<frames {
            let sample = Int16((Float(sin(2 * Double.pi * 440 * Double(i) / 48_000)) * amplitude
                                * Float(Int16.max)).rounded())
            var le = sample.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        try data.write(to: url)
    }

    /// Seeds one track + asset whose bookmark resolves to `url`.
    private static func seedTrack(in db: Database, title: String, url: URL) throws -> Int64 {
        var track = DJTrack(syncID: UUID().uuidString, title: title,
                            contentHash: "hash-\(title)", sortKey: title,
                            addedAt: Date(), updatedAt: Date())
        try track.insert(db)
        guard let id = track.id else { return 0 }
        var asset = DJAsset(trackID: id,
                            bookmark: BookmarkVault.makeBookmark(for: url),
                            relPath: url.lastPathComponent)
        try asset.insert(db)
        return id
    }

    private func makeCoordinator(pool: DatabasePool, trackURL: URL) -> AnalysisCoordinator {
        AnalysisCoordinator(pool: pool, assetURL: { trackID, db in
            Self.fetchURL(for: db, trackID: trackID) ?? trackURL
        })
    }

    private static func fetchURL(for db: Database, trackID: Int64) -> URL? {
        guard let asset = try? DJAsset.filter(Column("trackID") == trackID).fetchOne(db),
              let bookmark = asset.bookmark else { return nil }
        return BookmarkVault.resolve(bookmark)?.url
    }

    // MARK: - Pipeline determinism (NFR-DET-3)

    func testPipelineIsDeterministic() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordTests-det-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try makeToneWAV(at: url, seconds: 1.0)

        let a = try AnalyzePipeline.run(url: url)
        let b = try AnalyzePipeline.run(url: url)
        XCTAssertEqual(a.bpm, b.bpm)
        XCTAssertEqual(a.key?.camelot.code, b.key?.camelot.code)
        XCTAssertEqual(a.loudness?.integratedLUFS, b.loudness?.integratedLUFS)
        XCTAssertEqual(a.energy, b.energy)
        XCTAssertEqual(a.phraseCount, b.phraseCount)
        XCTAssertEqual(a.waveformLevels, b.waveformLevels)
        XCTAssertGreaterThan(a.waveformLevels, 0)
    }

    /// The determinism gate (NFR-DET-3, §47.4): the packed BLOB for a stage is
    /// byte-identical across runs of the same input.
    func testEnergyAndWaveformBlobsAreByteIdentical() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordTests-blob-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try makeToneWAV(at: url, seconds: 1.0)

        // Waveform pyramid → blob, twice.
        func waveformBlob() throws -> Data {
            let pcm = try AudioDecoder.decode(url)
            let pyramid = pcm.mono.withUnsafeBufferPointer {
                WaveformPyramidBuilder.build($0, sampleRate: 48_000)
            }
            return AnalysisBlobLayouts.encodeWaveformPyramid(pyramid, version: 1)
        }
        let blobA = try waveformBlob()
        let blobB = try waveformBlob()
        XCTAssertEqual(blobA, blobB, "waveform blob must be byte-identical (NFR-DET-3)")

        // Energy curve → blob, twice.
        func energyBlob() throws -> Data {
            let pcm = try AudioDecoder.decode(url)
            let stft = STFTConfig()
            let kernel = STFTKernel(config: stft)
            let spectra = pcm.mono.withUnsafeBufferPointer { kernel.spectra($0) }
            let hopSeconds = Double(stft.hopSize) / stft.sampleRate
            let envelope = OnsetDetector.envelope(spectra: spectra)
            let onsets = OnsetDetector.peaks(envelope, frameRateHz: 1 / hopSeconds)
            let tempo = TempoAnalyzer.estimate(novelty: envelope, hopSeconds: hopSeconds).first
            let grid = tempo.flatMap { BeatTracker.grid(novelty: envelope, hopSeconds: hopSeconds,
                                                        sampleRate: 48_000, onsets: onsets,
                                                        bpm: $0.bpm) }
            let frames = pcm.mono.withUnsafeBufferPointer { mono in
                spectra.enumerated().map { i, spec in
                    let prev = i > 0 ? spectra[i - 1].power : spec.power
                    let offset = stft.hopSize * i
                    let count = min(stft.fftSize, max(0, mono.count - offset))
                    let slice = UnsafeBufferPointer(start: mono.baseAddress!.advanced(by: offset),
                                                    count: count)
                    return SpectralFeatures.frame(spec, prevPower: prev, frameSamples: slice)
                }
            }
            let curve = grid.map {
                EnergyAnalyzer.curve(frames: frames, beatSamples: $0.beatSamples,
                                     frameRateHz: 1 / hopSeconds, sampleRate: 48_000)
            } ?? []
            return AnalysisBlobLayouts.encodeEnergyCurve(curve, hopSeconds: hopSeconds, version: 1)
        }
        let eA = try energyBlob()
        let eB = try energyBlob()
        XCTAssertEqual(eA, eB, "energy curve blob must be byte-identical (NFR-DET-3)")
    }

    // MARK: - Coordinator behaviour

    func testAnalyzePersistsInSingleTransaction() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordTests-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try makeToneWAV(at: url, seconds: 0.5)

        let trackID = try await pool.write { try Self.seedTrack(in: $0, title: "tone", url: url) }
        let coordinator = AnalysisCoordinator(pool: pool, assetURL: { trackID, db in
            try? Self.fetchURL(for: db, trackID: trackID)
        })
        await coordinator.analyzeAll()

        let loudness = try await pool.read { try DBRow.fetchOne($0, sql: "SELECT * FROM loudness WHERE trackID = ?", arguments: [trackID]) }
        XCTAssertNotNil(loudness)
        let keyCount = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM key_estimate WHERE trackID = ?", arguments: [trackID]) ?? 0
        }
        XCTAssertEqual(keyCount, 1)
        let state = try await pool.read {
            try String.fetchOne($0, sql: "SELECT analysisState FROM track WHERE id = ?", arguments: [trackID])
        }
        XCTAssertEqual(state, "analyzed")
        let runCount = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM analysis_run WHERE trackID = ? AND state = 'done'", arguments: [trackID]) ?? 0
        }
        XCTAssertEqual(runCount, 1)
    }

    func testReAnalyzeIsIdempotent() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordTests-idem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try makeToneWAV(at: url, seconds: 0.5)

        let trackID = try await pool.write { try Self.seedTrack(in: $0, title: "tone", url: url) }
        let coordinator = AnalysisCoordinator(pool: pool, assetURL: { trackID, db in
            try? Self.fetchURL(for: db, trackID: trackID)
        })
        await coordinator.analyzeAll()
        await coordinator.analyzeAll()

        // No duplicate rows despite two runs.
        let loudnessCount = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM loudness WHERE trackID = ?", arguments: [trackID]) ?? 0
        }
        XCTAssertEqual(loudnessCount, 1)
        let keyCount = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM key_estimate WHERE trackID = ?", arguments: [trackID]) ?? 0
        }
        XCTAssertEqual(keyCount, 1)
    }

    func testReconcileResetsStaleRunningToPending() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        // A crashed run: a `running` row with no `done`.
        try await pool.write { db in
            let trackID = try Self.seedTrack(in: db, title: "tone",
                                             url: URL(fileURLWithPath: "/nonexistent/x.wav"))
            try db.execute(sql: """
                INSERT INTO analysis_run (trackID, stage, version, state) VALUES (?, 'essentials', 1, 'running')
                """, arguments: [trackID])
            try db.execute(sql: "UPDATE track SET analysisState = 'running' WHERE id = ?",
                           arguments: [trackID])
        }
        let coordinator = AnalysisCoordinator(pool: pool, assetURL: { _, db in nil })
        _ = try await coordinator.reconcileVersions()
        let stale = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM analysis_run WHERE state = 'running'") ?? 0
        }
        XCTAssertEqual(stale, 0, "stale running rows must reset to pending")
    }

    func testPendingCountReflectsUnanalyzedTracks() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        try await pool.write { db in
            _ = try Self.seedTrack(in: db, title: "a",
                                   url: URL(fileURLWithPath: "/nonexistent/a.wav"))
            _ = try Self.seedTrack(in: db, title: "b",
                                   url: URL(fileURLWithPath: "/nonexistent/b.wav"))
        }
        let coordinator = AnalysisCoordinator(pool: pool, assetURL: { _, _ in nil })
        let count = try await coordinator.reconcileVersions()
        XCTAssertEqual(count, 2)
    }
}

/// Lightweight row proxy for assertions.
private struct DBRow: Codable, FetchableRecord {
    var trackID: Int64
}
