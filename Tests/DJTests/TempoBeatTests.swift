import XCTest
import Accelerate

@testable import TonearmDJ

/// Synthetic audio generators (Appendix R.1) — deterministic, no files, no
/// copyrighted material. Used by the tempo/beat/golden tests.
public enum SyntheticAudio {
    /// A click track at the given BPM: a half-frame Hann-windowed 1 kHz burst at
    /// each beat, with an accent on beat 1 of every bar so downbeat detection has
    /// something to find. Returns (mono samples @48k, hopSeconds).
    public static func clickTrack(bpm: Double, seconds: Double,
                                  beatsPerBar: Int = 4,
                                  accentAmplitude: Float = 0.9,
                                  beatAmplitude: Float = 0.45) -> [Float] {
        let beatInterval = 60.0 / bpm
        var samples = [Float](repeating: 0, count: Int(48_000 * seconds))
        var i = Int(0.5 * 48_000)
        var beatCount = 0
        while Double(i) / 48_000 < seconds {
            let isAccent = beatCount % beatsPerBar == 0
            let amplitude = isAccent ? accentAmplitude : beatAmplitude
            let start = i
            for j in 0..<2048 where start + j < samples.count {
                let t = Double(j) / 48_000
                let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(j) / 2047)
                samples[start + j] = amplitude * Float(sin(2 * Double.pi * 1000 * t)) * Float(hann)
            }
            i += Int(beatInterval * 48_000)
            beatCount += 1
        }
        return samples
    }

    /// Runs the STFT → onset pipeline, returning (envelope, hopSeconds).
    public static func onsetEnvelope(from samples: [Float]) -> ([Float], Double) {
        let config = STFTConfig(fftSize: 4096, hopSize: 2048)
        let kernel = STFTKernel(config: config)
        let spectra = samples.withUnsafeBufferPointer { kernel.spectra($0) }
        return (OnsetDetector.envelope(spectra: spectra), 2048.0 / 48_000.0)
    }
}

final class TempoTests: XCTestCase {
    /// The coarse comb estimator has ~±1 BPM granularity because consecutive
    /// candidate lags round to the same autocorrelation bins; the precise BPM
    /// is refined from the median beat interval at beat-tracking time (F.5).
    /// Golden-file assertions use the refined grid BPM.
    func testClickTrackAt124BPM() {
        let samples = SyntheticAudio.clickTrack(bpm: 124, seconds: 8)
        let (env, hopSeconds) = SyntheticAudio.onsetEnvelope(from: samples)
        let candidates = TempoAnalyzer.estimate(novelty: env, hopSeconds: hopSeconds)
        guard let best = candidates.first else {
            XCTFail("no tempo candidate")
            return
        }
        XCTAssertEqual(best.bpm, 124, accuracy: 1.0)
    }

    func testClickTrackAt90BPM() {
        let samples = SyntheticAudio.clickTrack(bpm: 90, seconds: 8)
        let (env, hopSeconds) = SyntheticAudio.onsetEnvelope(from: samples)
        let candidates = TempoAnalyzer.estimate(novelty: env, hopSeconds: hopSeconds)
        guard let best = candidates.first else {
            XCTFail("no tempo candidate")
            return
        }
        XCTAssertEqual(best.bpm, 90, accuracy: 1.0)
    }

    func testOctaveErrorResolvesToTrueTempo() {
        // A click track whose envelope could read as half-tempo is resolved by
        // the comb scoring: 120 must win over 60.
        let samples = SyntheticAudio.clickTrack(bpm: 120, seconds: 8)
        let (env, hopSeconds) = SyntheticAudio.onsetEnvelope(from: samples)
        let candidates = TempoAnalyzer.estimate(novelty: env, hopSeconds: hopSeconds)
        guard let best = candidates.first else {
            XCTFail("no tempo candidate")
            return
        }
        XCTAssertEqual(best.bpm, 120, accuracy: 1.0)
        XCTAssertNotEqual(best.bpm, 60, accuracy: 1.0)
    }

    func testRankingHasConfidenceDescending() {
        let samples = SyntheticAudio.clickTrack(bpm: 128, seconds: 8)
        let (env, hopSeconds) = SyntheticAudio.onsetEnvelope(from: samples)
        let candidates = TempoAnalyzer.estimate(novelty: env, hopSeconds: hopSeconds, topK: 3)
        XCTAssertEqual(candidates.map(\.rank), [0, 1, 2])
        XCTAssertGreaterThanOrEqual(candidates[0].confidence, candidates[1].confidence)
    }
}

final class BeatTests: XCTestCase {
    func testGridLandsOnClickBeats() {
        let bpm = 124.0
        let samples = SyntheticAudio.clickTrack(bpm: bpm, seconds: 8)
        let (env, hopSeconds) = SyntheticAudio.onsetEnvelope(from: samples)
        let peaks = OnsetDetector.peaks(env, frameRateHz: 1 / hopSeconds)
        let candidates = TempoAnalyzer.estimate(novelty: env, hopSeconds: hopSeconds)
        guard let best = candidates.first else { return XCTFail("no tempo") }

        let grid = BeatTracker.grid(novelty: env, hopSeconds: hopSeconds,
                                    sampleRate: 48_000, onsets: peaks,
                                    bpm: best.bpm)
        guard let grid else { return XCTFail("no grid") }

        // First few beats land near 0.5, 0.984, 1.468... s (0.5 s pre-roll).
        for (idx, sample) in grid.beatSamples.prefix(4).enumerated() {
            let expected = 0.5 + Double(idx) * 60.0 / bpm
            XCTAssertEqual(Double(sample) / 48_000, expected, accuracy: 0.04, "beat \(idx)")
        }
        // The grid BPM is refined from the median beat interval (F.5).
        XCTAssertEqual(grid.bpm, bpm, accuracy: 0.5)
        XCTAssertTrue(grid.isConstantTempo)
    }

    func testGridConfidenceNonNegative() {
        let samples = SyntheticAudio.clickTrack(bpm: 100, seconds: 6)
        let (env, hopSeconds) = SyntheticAudio.onsetEnvelope(from: samples)
        let peaks = OnsetDetector.peaks(env, frameRateHz: 1 / hopSeconds)
        let best = TempoAnalyzer.estimate(novelty: env, hopSeconds: hopSeconds).first
        guard let best else { return XCTFail("no tempo") }
        let grid = BeatTracker.grid(novelty: env, hopSeconds: hopSeconds,
                                    sampleRate: 48_000, onsets: peaks, bpm: best.bpm)
        XCTAssertNotNil(grid)
        XCTAssertTrue(grid?.confidence.allSatisfy { $0.isFinite && $0 >= 0 } ?? false)
    }
}

final class DownbeatTests: XCTestCase {
    func testAccentPatternSelectsBeatOneOffset() {
        let bpm = 120.0
        let samples = SyntheticAudio.clickTrack(bpm: bpm, seconds: 8)
        let (env, hopSeconds) = SyntheticAudio.onsetEnvelope(from: samples)
        let peaks = OnsetDetector.peaks(env, frameRateHz: 1 / hopSeconds)
        let best = TempoAnalyzer.estimate(novelty: env, hopSeconds: hopSeconds).first
        guard let best else { return XCTFail("no tempo") }
        guard let grid = BeatTracker.grid(novelty: env, hopSeconds: hopSeconds,
                                          sampleRate: 48_000, onsets: peaks,
                                          bpm: best.bpm) else {
            return XCTFail("no grid")
        }
        let downbeats = BeatTracker.downbeats(beatSamples: grid.beatSamples,
                                              novelty: env, hopSeconds: hopSeconds,
                                              sampleRate: 48_000)
        XCTAssertFalse(downbeats.isEmpty)
        // With accent on beat 1, beat 0 of each bar is a downbeat; the first
        // detected downbeat should be the very first beat.
        XCTAssertEqual(downbeats[0], 0)
    }

    func testUnaccentedTrackStillYieldsOffset() {
        // No accent: the offset is still well-defined (all equal), and every
        // 4th beat from an arbitrary start is picked.
        let bpm = 120.0
        let samples = SyntheticAudio.clickTrack(bpm: bpm, seconds: 6, beatsPerBar: 4,
                                                accentAmplitude: 0.6, beatAmplitude: 0.6)
        let (env, hopSeconds) = SyntheticAudio.onsetEnvelope(from: samples)
        let peaks = OnsetDetector.peaks(env, frameRateHz: 1 / hopSeconds)
        let best = TempoAnalyzer.estimate(novelty: env, hopSeconds: hopSeconds).first
        guard let best else { return XCTFail("no tempo") }
        guard let grid = BeatTracker.grid(novelty: env, hopSeconds: hopSeconds,
                                          sampleRate: 48_000, onsets: peaks,
                                          bpm: best.bpm) else {
            return XCTFail("no grid")
        }
        let downbeats = BeatTracker.downbeats(beatSamples: grid.beatSamples,
                                              novelty: env, hopSeconds: hopSeconds,
                                              sampleRate: 48_000)
        // Every 4th beat is a downbeat.
        XCTAssertEqual(downbeats, stride(from: downbeats[0], to: grid.beatSamples.count, by: 4).map { $0 })
    }
}
