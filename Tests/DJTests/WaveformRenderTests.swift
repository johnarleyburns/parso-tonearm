import XCTest
import GRDB
import TonearmCore

@testable import TonearmDJ

/// Commit 5.3 — the waveform render (plan 5.3, §26A, AT-WAVE-2..7). The
/// renderer draws from persisted analysis — band-split colour (AT-WAVE-2),
/// the composed grid the engine quantises to (AT-WAVE-3), phrase spans
/// (AT-WAVE-4), the honest empty state (AT-WAVE-5), sample-accurate markers
/// at every zoom (AT-WAVE-6), and §26A.7 pyramid-level selection (AT-WAVE-7).
@MainActor
final class WaveformRenderTests: XCTestCase {

    // MARK: - Helpers

    private func makePool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformRenderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        return (pool, dir)
    }

    private func seedTrack(pool: DatabasePool, bpm: Double = 128,
                           durationSec: Double = 30) async throws -> Int64 {
        let id = try await pool.write { db -> Int64? in
            var track = DJTrack(syncID: UUID().uuidString, title: "Render Test",
                                durationSec: durationSec, codec: "WAV",
                                contentHash: "hash-\(UUID().uuidString)",
                                sortKey: "render-test",
                                bpm: bpm,
                                addedAt: Date(), updatedAt: Date())
            track.sampleRate = 48_000
            try track.insert(db)
            return track.id
        }
        return try XCTUnwrap(id)
    }

    private func seedPyramid(pool: DatabasePool, trackID: Int64) async throws {
        let samples = [Float](repeating: 0.1, count: 48_000 * 2)
        let pyramid = samples.withUnsafeBufferPointer {
            WaveformPyramidBuilder.build($0, sampleRate: 48_000)
        }
        let blob = AnalysisBlobLayouts.encodeWaveformPyramid(pyramid,
                                                             version: AnalysisVersions.waveform)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO waveform_pyramid
                (trackID, levels, baseSamplesPerBin, channelLayout, blob, version)
                VALUES (?, ?, ?, 'mono', ?, ?)
                """, arguments: [trackID, pyramid.levels.count,
                                 pyramid.baseSamplesPerBin, blob,
                                 AnalysisVersions.waveform])
        }
    }

    private func seedBeatGrid(pool: DatabasePool, trackID: Int64,
                              bpm: Double = 128, firstBeat: Int64 = 24_000,
                              constantTempo: Bool = true,
                              storedBeats: [Int64]? = nil) async throws {
        let beats = storedBeats ?? (0..<96).map { firstBeat + Int64(Double($0) * (60.0 / bpm * 48_000)) }
        let confidence = [Float](repeating: 0.95, count: beats.count)
        let blob = AnalysisBlobLayouts.encodeBeatBlob(beats, confidence: confidence,
                                                      version: AnalysisVersions.beat)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO beat_grid
                (trackID, syncID, bpm, firstBeatSample, beatCount, isConstantTempo,
                 source, confidence, version, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, 'detected', ?, ?, ?)
                """, arguments: [trackID, "g-\(trackID)", bpm, firstBeat,
                                 beats.count, constantTempo ? 1 : 0, 0.95,
                                 AnalysisVersions.beat, Date()])
            try db.execute(sql: "INSERT INTO beat_blob (trackID, blob) VALUES (?, ?)",
                           arguments: [trackID, blob])
        }
    }

    private func seedCorrection(pool: DatabasePool, trackID: Int64,
                                op: String, valueInt: Int64? = nil,
                                valueDouble: Double? = nil) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO grid_correction (syncID, trackID, op, valueDouble, valueInt, appliedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: ["c-\(UUID().uuidString)", trackID, op,
                                 valueDouble, valueInt, Date()])
        }
    }

    private func synthSine(frequency: Double, seconds: Double,
                           amplitude: Float = 0.8) -> [Float] {
        let count = Int(48_000 * seconds)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / 48_000))
        }
    }

    // MARK: - AT-WAVE-2: frequency colouring (§26A.2)

    func testBandColourSplitPutsEnergyInTheExpectedBand() {
        let cases: [(frequency: Double, expected: WaveformBand)] = [
            (60, .low),
            (800, .mid),
            (8_000, .high),
        ]
        for testCase in cases {
            let samples = synthSine(frequency: testCase.frequency, seconds: 2)
            let pyramid = samples.withUnsafeBufferPointer {
                WaveformPyramidBuilder.build($0, sampleRate: 48_000)
            }
            let bins = pyramid.levels[0]
            XCTAssertGreaterThan(bins.count, 20)
            let settled = bins[10..<(bins.count - 10)]
            let dominants = settled.compactMap { WaveformBand.dominantBand(rms: $0.bandRMS) }
            XCTAssertEqual(dominants.count, settled.count,
                           "every settled bin carries band data")
            XCTAssertTrue(dominants.allSatisfy { $0 == testCase.expected },
                          "a \(testCase.frequency) Hz signal reads as \(testCase.expected) in every settled bin")
            // The stacked contributions are normalised and finite.
            for bin in settled {
                let contributions = WaveformBand.contributions(rms: bin.bandRMS)
                XCTAssertEqual(contributions.reduce(0, +), 1.0, accuracy: 1e-5,
                               "contributions normalise to the bin's total energy")
                XCTAssertTrue(contributions.allSatisfy { $0.isFinite && $0 >= 0 })
            }
        }
    }

    // MARK: - AT-WAVE-3: composed grid == the engine's quantise surface (§26A.3)

    func testGridComposedWithCorrectionMatchesEngineQuantise() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        let trackID = try await seedTrack(pool: pool, bpm: 128, durationSec: 30)
        try await seedBeatGrid(pool: pool, trackID: trackID, bpm: 128, firstBeat: 24_000)
        try await seedPyramid(pool: pool, trackID: trackID)
        // The prep surface's tap-to-set-downbeat: bar 1 moves to sample 48 000.
        try await seedCorrection(pool: pool, trackID: trackID, op: "setDownbeat", valueInt: 48_000)

        let rendered = try await WaveformRepository(pool: pool).renderModel(trackID: trackID)
        let model = try XCTUnwrap(rendered)
        let samplesPerBeat = 60.0 / 128.0 * 48_000

        XCTAssertEqual(model.grid.referenceSample, 48_000, accuracy: 1e-9,
                       "the correction re-anchors the authoritative grid")
        XCTAssertEqual(model.beats[0], 48_000)
        XCTAssertEqual(model.beats[1], Int64((48_000 + samplesPerBeat).rounded()),
                       "beats extrapolate from the corrected reference, sample for sample")

        // The engine quantises onto a model beat: a trigger just before beat 2
        // lands exactly on it (§30.3, AT-WAVE-3).
        let trigger = model.beats[1] - 100
        let quantised = Scheduler.quantizedBoundary(after: trigger,
                                                    resolution: .beat,
                                                    grid: model.grid)
        XCTAssertEqual(quantised, model.beats[1])
        XCTAssertTrue(model.beats.contains(quantised))

        // The immutable detected rows are untouched (§19.4 rule 3).
        let detected = try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT firstBeatSample, source FROM beat_grid WHERE trackID = ?
                """, arguments: [trackID])
        }
        XCTAssertEqual(detected?["firstBeatSample"] as? Int64, 24_000)
        XCTAssertEqual(detected?["source"] as? String, "detected")

        // Downbeats every beatsPerBar beats, bar 1 = first downbeat.
        XCTAssertEqual(model.downbeats[0], model.beats[0])
        XCTAssertEqual(model.downbeats[1], model.beats[4])
        XCTAssertEqual(model.barNumberOrigin, 1)
    }

    func testVariableTempoGridFollowsStoredBeatPositions() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        let trackID = try await seedTrack(pool: pool, bpm: 128, durationSec: 30)
        // A variable-tempo grid: real (slightly irregular) beat positions.
        let stored: [Int64] = [24_000, 46_500, 69_100, 91_800, 114_400, 137_100]
        try await seedBeatGrid(pool: pool, trackID: trackID, bpm: 128,
                               firstBeat: 24_000, constantTempo: false,
                               storedBeats: stored)
        try await seedPyramid(pool: pool, trackID: trackID)
        // A nudge shifts the whole grid by +2 000 samples.
        try await seedCorrection(pool: pool, trackID: trackID, op: "nudge", valueInt: 2_000)

        let rendered = try await WaveformRepository(pool: pool).renderModel(trackID: trackID)
        let model = try XCTUnwrap(rendered)
        XCTAssertFalse(model.isConstantTempo)
        XCTAssertEqual(model.beats, stored.map { $0 + 2_000 },
                       "a variable-tempo grid follows the stored per-beat positions, re-anchored (§26A.3)")
    }

    // MARK: - AT-WAVE-4: phrase ribbon spans (§26A.4)

    func testPhraseRibbonSpansEqualPersistedRowsAndMarkLowConfidence() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        let trackID = try await seedTrack(pool: pool, bpm: 128, durationSec: 30)
        try await seedBeatGrid(pool: pool, trackID: trackID)
        try await seedPyramid(pool: pool, trackID: trackID)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO phrase (syncID, trackID, startSample, endSample, startBeat,
                                    lengthBeats, type, energy, confidence, version)
                VALUES ('p1', ?, 24000, 973909, 0, 64, 'intro', 3.0, 0.95, ?),
                       ('p2', ?, 973909, 1923818, 64, 64, 'drop', 8.0, 0.40, ?),
                       ('p3', ?, 1923818, 2500000, 128, 16, 'outro', 2.0, 0.90, ?)
                """, arguments: [trackID, AnalysisVersions.phrase,
                                 trackID, AnalysisVersions.phrase,
                                 trackID, AnalysisVersions.phrase])
        }

        let rendered = try await WaveformRepository(pool: pool).renderModel(trackID: trackID)
        let model = try XCTUnwrap(rendered)
        XCTAssertEqual(model.phrases.count, 3)
        let intro = model.phrases[0]
        XCTAssertEqual(intro.startSample, 24_000)
        XCTAssertEqual(intro.endSample, 973_909)
        XCTAssertEqual(intro.type, .intro)
        XCTAssertEqual(intro.barCount, 16, "64 beats ÷ 4 beats/bar = 16 bars — bars, not seconds")
        XCTAssertFalse(intro.isLowConfidence, "0.95 is above the display threshold")

        let drop = model.phrases[1]
        XCTAssertEqual(drop.type, .drop)
        XCTAssertEqual(drop.barCount, 16)
        XCTAssertTrue(drop.isLowConfidence,
                      "0.40 is below the threshold — marked (dashed), never hidden (§26A.4)")

        let outro = model.phrases[2]
        XCTAssertEqual(outro.barCount, 4, "16 beats = 4 bars")
        XCTAssertEqual(outro.endSample, 2_500_000)
        XCTAssertEqual(outro.startSample, 1_923_818)
    }

    // MARK: - AT-WAVE-5: honest empty state (§26A.1)

    func testUnanalysedTrackRendersNilModel() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        // A track with a grid but no pyramid — analysed by a pre-5.2 build.
        let trackID = try await seedTrack(pool: pool)
        try await seedBeatGrid(pool: pool, trackID: trackID)

        let repository = WaveformRepository(pool: pool)
        let model = try await repository.renderModel(trackID: trackID)
        XCTAssertNil(model, "an unanalysed track has no render model — the honest empty state")
        XCTAssertFalse(model?.hasAnalysis ?? false)
    }

    func testAnalysedTrackYieldsANonNilModel() async throws {
        let (pool, cleanupDir) = try makePool()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        let trackID = try await seedTrack(pool: pool)
        try await seedBeatGrid(pool: pool, trackID: trackID)
        try await seedPyramid(pool: pool, trackID: trackID)

        let rendered = try await WaveformRepository(pool: pool).renderModel(trackID: trackID)
        let model = try XCTUnwrap(rendered)
        XCTAssertTrue(model.hasAnalysis)
        XCTAssertFalse(model.beats.isEmpty)
        XCTAssertGreaterThan(model.durationSamples, 0)
    }

    // MARK: - AT-WAVE-6: markers land on their sample positions at every zoom (§26A.6)

    func testMarkersLandOnSamplePositionsAtEveryZoom() {
        let markerSample: Int64 = 7_777_000
        let windowStart: Double = 3_000_000
        for samplesPerPoint in [2.0, 64.0, 512.0, 4_000.0, 40_000.0] {
            let x = WaveformGeometry.x(sample: markerSample,
                                       windowStart: windowStart,
                                       samplesPerPoint: samplesPerPoint)
            // Round-trip: the rendered position maps back to the exact sample.
            let recovered = WaveformGeometry.sample(atX: x,
                                                    windowStart: windowStart,
                                                    samplesPerPoint: samplesPerPoint)
            XCTAssertEqual(recovered, markerSample,
                           "a marker never drifts against the grid at \(samplesPerPoint) samples/pt")
        }
    }

    func testQuantisedSeekTargetSnapsToAGridBeat() {
        let model = WaveformRenderModel(pyramid: WaveformPyramid(levels: [], sampleRate: 48_000, baseSamplesPerBin: 256),
                                        peaks: [],
                                        beats: [48_000, 70_500, 93_000],
                                        downbeats: [48_000],
                                        barNumberOrigin: 1,
                                        phrases: [],
                                        cues: [],
                                        activeLoop: nil,
                                        grid: DeckGrid(referenceSample: 48_000, bpm: 128, sampleRate: 48_000),
                                        durationSamples: 100_000,
                                        isConstantTempo: true)
        XCTAssertEqual(OverviewStrip.quantisedSeekTarget(sample: 71_000, model: model), 70_500,
                       "a tap just after a beat seeks to that beat (§26A.5, §33)")
        XCTAssertEqual(OverviewStrip.quantisedSeekTarget(sample: 92_000, model: model), 93_000)
    }

    // MARK: - AT-WAVE-7: pyramid-level selection (§26A.7)

    private func makePyramid(base: Int = 256, levels: Int = 8) -> WaveformPyramid {
        var all: [[WaveformBin]] = []
        var count = 4096
        for _ in 0..<levels {
            all.append(Array(repeating: WaveformBin(min: -0.5, max: 0.5, rms: 0.3,
                                                    bandRMS: [0.2, 0.1, 0.05]),
                             count: count))
            count /= 2
        }
        return WaveformPyramid(levels: all, sampleRate: 48_000, baseSamplesPerBin: base)
    }

    func testLevelSelectionPicksCoarsestLevelWithinOnePixelPerBin() {
        let pyramid = makePyramid()
        // Level bin sizes: 256, 512, 1024, 2048, 4096, 8192, 16384, 32768.
        // At 1000 samples/pt the coarsest bin ≤ 1000 is level 1 (512).
        XCTAssertEqual(WaveformLevelSelector.level(samplesPerPoint: 1_000,
                                                   thermal: .nominal,
                                                   pyramid: pyramid), 1)
        // At 5000 samples/pt: coarsest ≤ 5000 is level 4 (4096).
        XCTAssertEqual(WaveformLevelSelector.level(samplesPerPoint: 5_000,
                                                   thermal: .nominal,
                                                   pyramid: pyramid), 4)
        // At 40 000 samples/pt: level 7 (32 768 ≤ 40 000).
        XCTAssertEqual(WaveformLevelSelector.level(samplesPerPoint: 40_000,
                                                   thermal: .nominal,
                                                   pyramid: pyramid), 7)
        // Very zoomed in: clamp to the finest level, never finer than it.
        XCTAssertEqual(WaveformLevelSelector.level(samplesPerPoint: 100,
                                                   thermal: .nominal,
                                                   pyramid: pyramid), 0)
    }

    func testSeriousStepsOneLevelCoarser() {
        let pyramid = makePyramid()
        for samplesPerPoint in [1_000.0, 5_000.0, 40_000.0, 100.0] {
            let nominal = WaveformLevelSelector.level(samplesPerPoint: samplesPerPoint,
                                                      thermal: .nominal,
                                                      pyramid: pyramid)
            let serious = WaveformLevelSelector.level(samplesPerPoint: samplesPerPoint,
                                                      thermal: .serious,
                                                      pyramid: pyramid)
            XCTAssertEqual(serious, min(nominal + 1, pyramid.levels.count - 1),
                           "§26A.7 steps exactly one level coarser at .serious")
        }
    }
}
