import XCTest
import Accelerate

@testable import TonearmDJ

/// Golden-file regression for the tempo/beat/downbeat pipeline (Appendix R.2).
/// Fixtures are synthetic (Appendix R.1) so they are license-clean and need no
/// network fetch or checked-in audio. The golden values are literals with
/// tolerances; a pipeline change that moves a value outside its tolerance
/// fails — that is the determinism gate (NFR-DET-3, §47.4).
final class GoldenTempoBeatTests: XCTestCase {

    private struct Golden: Equatable {
        let bpm: Double
        let bpmTolerance: Double
        let firstDownbeatSec: Double
        let downbeatToleranceSec: Double
    }

    /// The checked-in expected analyses (Appendix R.2 semantics): numeric
    /// fields assert within their stated tolerance. Calibrated on first run,
    /// then frozen — a diff without a version bump fails.
    private static let goldens: [Int: Golden] = [
        124: Golden(bpm: 124, bpmTolerance: 0.5,
                    firstDownbeatSec: 0.5, downbeatToleranceSec: 0.04),
        100: Golden(bpm: 100, bpmTolerance: 0.5,
                    firstDownbeatSec: 0.5, downbeatToleranceSec: 0.04),
        120: Golden(bpm: 120, bpmTolerance: 0.5,
                    firstDownbeatSec: 0.5, downbeatToleranceSec: 0.04),
    ]

    /// Runs the full pipeline: click track -> onset envelope -> tempo -> grid.
    private func analyze(bpm: Double) -> (grid: BeatGrid, downbeats: [Int])? {
        let samples = SyntheticAudio.clickTrack(bpm: bpm, seconds: 8)
        let (env, hopSeconds) = SyntheticAudio.onsetEnvelope(from: samples)
        let peaks = OnsetDetector.peaks(env, frameRateHz: 1 / hopSeconds)
        guard let best = TempoAnalyzer.estimate(novelty: env, hopSeconds: hopSeconds).first,
              let grid = BeatTracker.grid(novelty: env, hopSeconds: hopSeconds,
                                          sampleRate: 48_000, onsets: peaks, bpm: best.bpm) else {
            return nil
        }
        let downbeats = BeatTracker.downbeats(beatSamples: grid.beatSamples,
                                              novelty: env, hopSeconds: hopSeconds,
                                              sampleRate: 48_000)
        return (grid, downbeats)
    }

    private func assertGolden(_ bpm: Int) throws {
        let golden = try XCTUnwrap(Self.goldens[bpm])
        guard let result = analyze(bpm: Double(bpm)) else { return XCTFail("no analysis for \(bpm)") }
        XCTAssertEqual(result.grid.bpm, golden.bpm, accuracy: golden.bpmTolerance,
                       "grid BPM drifted for \(bpm) BPM")
        XCTAssertNotNil(result.downbeats.first, "no downbeats for \(bpm) BPM")
        let firstDownbeatSec = Double(result.grid.beatSamples[result.downbeats.first!]) / 48_000
        XCTAssertEqual(firstDownbeatSec, golden.firstDownbeatSec,
                       accuracy: golden.downbeatToleranceSec,
                       "first downbeat drifted for \(bpm) BPM")
    }

    func testGoldenClickTrack124() throws { try assertGolden(124) }
    func testGoldenClickTrack100() throws { try assertGolden(100) }
    func testGoldenClickTrack120() throws { try assertGolden(120) }

    func testAnalysisIsDeterministic() {
        // Same input, same output — the determinism gate (NFR-DET-3).
        guard let a = analyze(bpm: 120) else { return XCTFail("no analysis") }
        guard let b = analyze(bpm: 120) else { return XCTFail("no analysis") }
        XCTAssertEqual(a.grid.beatSamples, b.grid.beatSamples)
        XCTAssertEqual(a.grid.bpm, b.grid.bpm)
        XCTAssertEqual(a.downbeats, b.downbeats)
    }
}
