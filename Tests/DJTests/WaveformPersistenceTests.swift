import XCTest
import GRDB
import TonearmCore

@testable import TonearmDJ

/// Commit 5.2 — analysis persistence (plan 5.2, §19.4, AT-WAVE-1). The
/// pipeline's computed artifacts reach their destination tables — a **real**
/// beat grid, downbeats, phrases, the band-split waveform pyramid and the
/// energy curve — in the one existing persist transaction; re-analysis is
/// idempotent per version; and the §23.3 `grid_correction` log still replays
/// over the immutable rows without ever touching them.
@MainActor
final class WaveformPersistenceTests: XCTestCase {

    // MARK: - Helpers

    private func makePool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tonearm-dj.sqlite")
        let pool = try DJDatabase.open(at: url)
        return (pool, dir)
    }

    /// Writes a 48 kHz mono 16-bit PCM WAV from raw Float32 samples — a real
    /// file AVFoundation decodes through the full pipeline.
    private func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        var size = UInt32(36 + samples.count * 2)
        data.append(Data(bytes: &size, count: 4))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        var fmtSize = UInt32(16); data.append(Data(bytes: &fmtSize, count: 4))
        var pcm: UInt16 = 1; data.append(Data(bytes: &pcm, count: 2))
        var mono: UInt16 = 1; data.append(Data(bytes: &mono, count: 2))
        var sampleRate: UInt32 = 48_000; data.append(Data(bytes: &sampleRate, count: 4))
        var byteRate = sampleRate * 2; data.append(Data(bytes: &byteRate, count: 4))
        var align: UInt16 = 2; data.append(Data(bytes: &align, count: 2))
        var bits: UInt16 = 16; data.append(Data(bytes: &bits, count: 2))
        data.append(contentsOf: Array("data".utf8))
        var dataSize = UInt32(samples.count * 2); data.append(Data(bytes: &dataSize, count: 4))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var le = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        try data.write(to: url)
    }

    /// A click track with a real beat structure (the Appendix R.1 fixture), so
    /// the grid, downbeats and phrases are all genuine — no placeholders.
    private func makeClickWAV(at url: URL, bpm: Double = 124, seconds: Double = 24) throws {
        let samples = SyntheticAudio.clickTrack(bpm: bpm, seconds: seconds)
        try writeWAV(samples, to: url)
    }

    /// Seeds one track + asset whose bookmark resolves to `url`.
    nonisolated private static func seedTrack(in db: Database, title: String, url: URL) throws -> Int64 {
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
        AnalysisCoordinator(pool: pool, assetURL: { _, _ in trackURL })
    }

    // MARK: - AT-WAVE-1: every §19.4 artifact persists with real values

    func testAnalysisPersistsAllFiveArtifactsWithRealValues() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("click.wav")
        try makeClickWAV(at: url)

        // The expected analysis, computed directly. Deterministic (NFR-DET-3),
        // so the persisted rows must match it exactly.
        let expected = try AnalyzePipeline.run(url: url)
        let grid = try XCTUnwrap(expected.beatGrid, "the click track must yield a beat grid")
        XCTAssertFalse(expected.downbeats.isEmpty, "the click track must yield downbeats")
        XCTAssertFalse(expected.phrases.isEmpty, "the click track must yield phrases")
        let pyramid = try XCTUnwrap(expected.waveform, "the click track must yield a waveform pyramid")
        XCTAssertFalse(expected.energyCurve.isEmpty, "the click track must yield an energy curve")

        let trackID = try await pool.write { try Self.seedTrack(in: $0, title: "click", url: url) }
        let coordinator = makeCoordinator(pool: pool, trackURL: url)
        await coordinator.analyzeAll()

        // — beat_grid: real values, never the placeholder (0, 0) —
        let beatGrid = try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT bpm, firstBeatSample, beatCount, isConstantTempo, confidence,
                       source, version
                FROM beat_grid WHERE trackID = ?
                """, arguments: [trackID])
        }
        let beatCount = beatGrid?["beatCount"] as? Int64 ?? 0
        let firstBeatSample = beatGrid?["firstBeatSample"] as? Int64 ?? 0
        XCTAssertGreaterThan(beatCount, 0, "beat_grid.beatCount is never a placeholder zero")
        XCTAssertEqual(beatCount, Int64(grid.beatSamples.count))
        XCTAssertEqual(firstBeatSample, grid.firstBeatSample,
                       "the header's first beat is the grid's, not a placeholder")
        XCTAssertEqual(beatGrid?["bpm"] as? Double ?? 0, grid.bpm, accuracy: 1e-9)
        XCTAssertEqual((beatGrid?["isConstantTempo"] as? Int64 ?? 0) != 0, grid.isConstantTempo)
        XCTAssertEqual(beatGrid?["source"] as? String, "detected")
        XCTAssertEqual(beatGrid?["version"] as? Int64, Int64(AnalysisVersions.beat))
        XCTAssertNotNil(beatGrid?["confidence"], "a real grid carries a real confidence")

        // — beat_blob: per-beat sample positions + confidence —
        let blobData = try await pool.read { db in
            try Data.fetchOne(db, sql: "SELECT blob FROM beat_blob WHERE trackID = ?",
                              arguments: [trackID])
        }
        let decodedBlob = try AnalysisBlobLayouts.decodeBeatBlob(try XCTUnwrap(blobData))
        XCTAssertEqual(decodedBlob.count, Int(beatCount))
        XCTAssertEqual(decodedBlob.samples, grid.beatSamples)
        XCTAssertEqual(decodedBlob.confidence, grid.confidence)
        XCTAssertTrue(zip(decodedBlob.samples, decodedBlob.samples.dropFirst())
                        .allSatisfy { $0 < $1 },
                      "beat positions must be strictly increasing")

        // — downbeat rows: one per bar start, anchored to the blob —
        let downbeatRows = try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT beatIndex, samplePosition, barNumber FROM downbeat
                WHERE trackID = ? ORDER BY beatIndex
                """, arguments: [trackID])
        }
        XCTAssertEqual(downbeatRows.count, expected.downbeats.count)
        for (i, row) in downbeatRows.enumerated() {
            let beatIndex = row["beatIndex"] as? Int64 ?? -1
            XCTAssertEqual(Int(beatIndex), expected.downbeats[i])
            XCTAssertEqual(row["samplePosition"] as? Int64,
                           grid.beatSamples[expected.downbeats[i]],
                           "a downbeat row's sample is its beat's, from the blob")
            XCTAssertEqual(row["barNumber"] as? Int64, Int64(i + 1),
                           "bar numbers are sequential from 1")
        }

        // — phrase rows: real sample spans, bar-aligned lengths —
        let phraseRows = try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT startSample, endSample, startBeat, lengthBeats, type,
                       energy, confidence, version
                FROM phrase WHERE trackID = ? ORDER BY startBeat, id
                """, arguments: [trackID])
        }
        XCTAssertEqual(phraseRows.count, expected.phrases.count)
        for (i, row) in phraseRows.enumerated() {
            let phrase = expected.phrases[i]
            XCTAssertEqual(row["startSample"] as? Int64, phrase.startSample)
            XCTAssertEqual(row["endSample"] as? Int64, phrase.endSample)
            XCTAssertEqual(row["startBeat"] as? Int64, Int64(phrase.startBeat))
            XCTAssertEqual(row["lengthBeats"] as? Int64, Int64(phrase.lengthBeats))
            XCTAssertEqual(row["type"] as? String, phrase.type.rawValue)
            XCTAssertEqual(row["energy"] as? Double ?? 0, Double(phrase.energy), accuracy: 1e-5)
            XCTAssertEqual(row["confidence"] as? Double ?? 0, phrase.confidence, accuracy: 1e-5)
            XCTAssertEqual(row["version"] as? Int64, Int64(AnalysisVersions.phrase))
        }

        // — waveform_pyramid: band-split BLOB (FR-WAVE-2's only source) —
        let waveRow = try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT levels, baseSamplesPerBin, channelLayout, blob, version
                FROM waveform_pyramid WHERE trackID = ?
                """, arguments: [trackID])
        }
        XCTAssertEqual(waveRow?["levels"] as? Int64, Int64(pyramid.levels.count))
        XCTAssertEqual(waveRow?["baseSamplesPerBin"] as? Int64, Int64(pyramid.baseSamplesPerBin))
        XCTAssertEqual(waveRow?["channelLayout"] as? String, "mono")
        XCTAssertEqual(waveRow?["version"] as? Int64, Int64(AnalysisVersions.waveform))
        let decodedPyramid = try AnalysisBlobLayouts
            .decodeWaveformPyramid(try XCTUnwrap(waveRow?["blob"] as? Data))
        XCTAssertEqual(decodedPyramid.levels.count, pyramid.levels.count)
        XCTAssertEqual(decodedPyramid.baseSamplesPerBin, pyramid.baseSamplesPerBin)
        XCTAssertEqual(decodedPyramid.levels.first?.first?.bandRMS.count, 3,
                       "low/mid/high band split rides inside the pyramid blob")

        // — energy_curve: the per-beat BLOB —
        let energyRow = try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT resolution, count, blob FROM energy_curve WHERE trackID = ?
                """, arguments: [trackID])
        }
        XCTAssertEqual(energyRow?["resolution"] as? String, "beat")
        XCTAssertEqual(energyRow?["count"] as? Int64, Int64(expected.energyCurve.count))
        let decodedCurve = try AnalysisBlobLayouts
            .decodeEnergyCurve(try XCTUnwrap(energyRow?["blob"] as? Data))
        XCTAssertEqual(decodedCurve.values, expected.energyCurve)

        // — the §19.4 read seam returns the same values —
        let store = DJLibraryStore(pool: pool)
        let storedPhrases = try await store.phrases(trackID: trackID)
        let storedDownbeats = try await store.downbeats(trackID: trackID)
        XCTAssertEqual(storedPhrases.count, expected.phrases.count)
        XCTAssertEqual(storedDownbeats.count, expected.downbeats.count)
        let gridValue = try await store.beatGrid(trackID: trackID)
        let storedGrid = try XCTUnwrap(gridValue)
        XCTAssertEqual(storedGrid.beatSamples, grid.beatSamples)
        XCTAssertEqual(storedGrid.firstBeatSample, grid.firstBeatSample)
        XCTAssertEqual(storedGrid.bpm, grid.bpm, accuracy: 1e-9)
        let pyramidValue = try await store.waveformPyramid(trackID: trackID)
        let storedPyramid = try XCTUnwrap(pyramidValue)
        XCTAssertEqual(storedPyramid.levels.count, pyramid.levels.count)
        let curveValue = try await store.energyCurve(trackID: trackID)
        let storedCurve = try XCTUnwrap(curveValue)
        XCTAssertEqual(storedCurve.values, expected.energyCurve)
    }

    // MARK: - Re-analysis idempotence (§19.4 rule 2)

    func testReAnalysisIsIdempotentPerVersion() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("click.wav")
        try makeClickWAV(at: url)

        let trackID = try await pool.write { try Self.seedTrack(in: $0, title: "click", url: url) }
        let coordinator = makeCoordinator(pool: pool, trackURL: url)
        await coordinator.analyzeAll()

        func counts() throws -> (phrase: Int, downbeat: Int, grid: Int, blob: Int,
                                 wave: Int, energy: Int) {
            try pool.read { db in
                func count(_ sql: String) -> Int {
                    (try? Int.fetchOne(db, sql: sql, arguments: [trackID])) ?? 0
                }
                return (count("SELECT COUNT(*) FROM phrase WHERE trackID = ?"),
                        count("SELECT COUNT(*) FROM downbeat WHERE trackID = ?"),
                        count("SELECT COUNT(*) FROM beat_grid WHERE trackID = ?"),
                        count("SELECT COUNT(*) FROM beat_blob WHERE trackID = ?"),
                        count("SELECT COUNT(*) FROM waveform_pyramid WHERE trackID = ?"),
                        count("SELECT COUNT(*) FROM energy_curve WHERE trackID = ?"))
            }
        }
        let first = try counts()

        // Re-analysis (the ordinary re-analysis prompt path): reset the state
        // and run the coordinator again — same version, same input.
        try await pool.write { db in
            try db.execute(sql: "UPDATE track SET analysisState = 'pending' WHERE id = ?",
                           arguments: [trackID])
        }
        await coordinator.analyzeAll()

        let second = try counts()
        XCTAssertEqual(second.phrase, first.phrase,
                       "re-analysis replaces phrase rows, never appends (§19.4 rule 2)")
        XCTAssertEqual(second.downbeat, first.downbeat)
        XCTAssertGreaterThan(first.phrase, 0)
        XCTAssertEqual(second.grid, 1, "the single-row artifact tables stay single-row")
        XCTAssertEqual(second.blob, 1)
        XCTAssertEqual(second.wave, 1)
        XCTAssertEqual(second.energy, 1)
    }

    // MARK: - Grid corrections never mutate the immutable rows (§19.4 rule 3)

    func testGridCorrectionStillOverridesWithoutMutatingArtifacts() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("click.wav")
        try makeClickWAV(at: url)

        let trackID = try await pool.write { try Self.seedTrack(in: $0, title: "click", url: url) }
        let coordinator = makeCoordinator(pool: pool, trackURL: url)
        await coordinator.analyzeAll()

        // Snapshot the immutable analysis before the correction.
        let before = try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT bpm, firstBeatSample, beatCount, source FROM beat_grid
                WHERE trackID = ?
                """, arguments: [trackID])
        }
        let phraseCountBefore = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM phrase WHERE trackID = ?",
                             arguments: [trackID]) ?? 0
        }

        // Append a correction through the prep repository — the §23.3
        // authoritative override log.
        let repository = GridCorrectionRepository(pool: pool, store: DJLibraryStore(pool: pool))
        try await repository.apply(.setDownbeat, trackID: trackID, valueDouble: nil, valueInt: 24_000)

        // The authoritative grid a deck loads reflects the correction…
        let snapshot = try await repository.snapshot(trackID: trackID)
        XCTAssertEqual(snapshot.grid?.referenceSample ?? -1, 24_000, accuracy: 1e-9)
        XCTAssertEqual(snapshot.detectedBPM, before?["bpm"] as? Double,
                       "the detected BPM is preserved separately from the correction")

        // …but the immutable analysis rows are untouched (§19.4 rule 3).
        let after = try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT bpm, firstBeatSample, beatCount, source FROM beat_grid
                WHERE trackID = ?
                """, arguments: [trackID])
        }
        XCTAssertEqual(after?["bpm"] as? Double, before?["bpm"] as? Double)
        XCTAssertEqual(after?["firstBeatSample"] as? Int64, before?["firstBeatSample"] as? Int64)
        XCTAssertEqual(after?["beatCount"] as? Int64, before?["beatCount"] as? Int64)
        XCTAssertEqual(after?["source"] as? String, "detected")
        let phraseCountAfter = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM phrase WHERE trackID = ?",
                             arguments: [trackID]) ?? 0
        }
        XCTAssertEqual(phraseCountAfter, phraseCountBefore,
                       "a grid correction never rewrites the phrase rows")
    }
}
