import XCTest
import Accelerate

@testable import TonearmCore
@testable import TonearmDJ

final class PCMBufferTests: XCTestCase {
    func testMonoSumMatchesChannelMean() {
        let left = [Float](repeating: 0.5, count: 8)
        let right = [Float](repeating: 0.25, count: 8)
        let buffer = PCMBuffer(sampleRate: 48_000, channels: [left, right])
        XCTAssertEqual(buffer.channelCount, 2)
        XCTAssertEqual(buffer.frameCount, 8)
        for i in 0..<8 {
            XCTAssertEqual(buffer.mono[i], 0.375, accuracy: 0.0001)
        }
    }

    func testSingleChannelMonoIsTheChannel() {
        let mono = [Float](repeating: 0.1, count: 4)
        let buffer = PCMBuffer(sampleRate: 48_000, channels: [mono])
        XCTAssertEqual(buffer.channelCount, 1)
        for i in 0..<4 {
            XCTAssertEqual(buffer.mono[i], 0.1, accuracy: 0.0001)
        }
    }

    func testEmptyBufferHasNoCrashAndZeroFrames() {
        let buffer = PCMBuffer(sampleRate: 48_000, channels: [])
        XCTAssertEqual(buffer.frameCount, 0)
        XCTAssertEqual(buffer.mono.count, 0)
    }

    func testChannelsAreDeinterleaved() {
        let left = [Float](arrayLiteral: 1, 3, 5, 7)
        let right = [Float](arrayLiteral: 2, 4, 6, 8)
        let buffer = PCMBuffer(sampleRate: 48_000, channels: [left, right])
        XCTAssertEqual(Array(buffer.channels[0]), left)
        XCTAssertEqual(Array(buffer.channels[1]), right)
    }
}

final class LoudnessTests: XCTestCase {
    /// A 1 kHz sine at the given amplitude, 48 kHz.
    private func sine(amplitude: Float, seconds: Double = 10) -> PCMBuffer {
        let frameCount = Int(48_000 * seconds)
        var samples = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let t = Double(i) / 48_000
            samples[i] = amplitude * Float(sin(2 * Double.pi * 1000 * t))
        }
        return PCMBuffer(sampleRate: 48_000, channels: [samples])
    }

    func testSilenceReturnsNoIntegratedLoudness() {
        let buffer = PCMBuffer(sampleRate: 48_000,
                               channels: [[Float](repeating: 0, count: 48_000 * 10)])
        let result = LoudnessAnalyzer.analyze(buffer)
        XCTAssertNil(result.integratedLUFS)
        XCTAssertNil(result.replayGainDB)
    }

    func testDoublingAmplitudeRaisesLoudnessAboutSixDB() {
        let quiet = LoudnessAnalyzer.analyze(sine(amplitude: 0.1))
        let loud = LoudnessAnalyzer.analyze(sine(amplitude: 0.2))
        guard let q = quiet.integratedLUFS, let l = loud.integratedLUFS else {
            XCTFail("expected integrated loudness")
            return
        }
        XCTAssertEqual(l - q, 6.0, accuracy: 0.5)
    }

    func testTruePeakRisesWithAmplitude() {
        let a = LoudnessAnalyzer.analyze(sine(amplitude: 0.5))
        let b = LoudnessAnalyzer.analyze(sine(amplitude: 1.0))
        guard let pa = a.truePeakDBTP, let pb = b.truePeakDBTP else {
            XCTFail("expected true peak")
            return
        }
        XCTAssertEqual(pb - pa, 6.02, accuracy: 0.5)
        // Phase 5b: true peak is now libebur128's, measured on the raw signal
        // (not the K-weighted one Tonearm's old analyzer used), so a full-scale
        // sine sits right at 0 dBTP rather than being pushed above it.
        XCTAssertEqual(pb, 0, accuracy: 0.3)
    }

    func testReplayGainIsMinus18MinusIntegrated() {
        let result = LoudnessAnalyzer.analyze(sine(amplitude: 0.3))
        guard let lufs = result.integratedLUFS, let gain = result.replayGainDB else {
            XCTFail("expected loudness + gain")
            return
        }
        XCTAssertEqual(gain, -18 - lufs, accuracy: 0.0001)
        XCTAssertEqual(result.version, AnalysisVersions.loudness)
    }

    func testLoudnessRangeNonNegative() {
        let result = LoudnessAnalyzer.analyze(sine(amplitude: 0.5))
        XCTAssertNotNil(result.loudnessRangeLU)
        XCTAssertGreaterThanOrEqual(result.loudnessRangeLU ?? -1, 0)
    }

    func testNoNaNsOnEdgeInputs() {
        let dc = PCMBuffer(sampleRate: 48_000,
                           channels: [[Float](repeating: 1, count: 48_000)])
        let result = LoudnessAnalyzer.analyze(dc)
        for value in [result.integratedLUFS, result.truePeakDBTP, result.replayGainDB,
                      result.dynamicRangeDB, result.loudnessRangeLU] {
            if let v = value { XCTAssertTrue(v.isFinite) }
        }
    }
}

final class ReplayGainCrossCheckTests: XCTestCase {
    /// The DJ-computed ReplayGain must agree with how the player applies gain
    /// (TonearmCore.ReplayGain.appliedGain), so a track the DJ analysis says is
    /// quiet is actually boosted on deck load (§20.1 cross-check).
    func testComputedGainMatchesPlayerGainApplication() {
        let frameCount = 48_000 * 8
        var samples = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let t = Double(i) / 48_000
            samples[i] = 0.05 * Float(sin(2 * Double.pi * 440 * t))
        }
        let buffer = PCMBuffer(sampleRate: 48_000, channels: [samples])
        let result = LoudnessAnalyzer.analyze(buffer)
        guard let gainDB = result.replayGainDB else {
            XCTFail("expected replay gain")
            return
        }

        // A quiet track should receive a positive (boosting) gain.
        XCTAssertGreaterThan(gainDB, 0)

        let tags = ReplayGain.Tags(trackGainDB: gainDB, albumGainDB: nil,
                                    trackPeak: nil, albumPeak: nil)
        let applied = ReplayGain.appliedGain(mode: .track, tags: tags)
        let expected = pow(10, gainDB / 20)
        XCTAssertEqual(applied, expected, accuracy: 0.0001)
    }
}
