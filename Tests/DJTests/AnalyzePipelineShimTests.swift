import XCTest
import ParsoAudioAnalysis

@testable import TonearmDJ

/// Phase 5b: the Stage-1 DSP now lives in `ParsoAudioAnalysis.FullAnalysis`.
/// `AnalyzePipeline.run` is a thin adapter that maps `FullAnalysisResult` onto
/// the coordinator's persist contract and layers on the loudness shim
/// (`replayGainDB` / `dynamicRangeDB`, §20.1). These tests pin that seam.
final class AnalyzePipelineShimTests: XCTestCase {

    /// A 10 s stereo 1 kHz tone at −6 dBFS, 48 kHz — enough for the loudness
    /// gates and one 3 s LRA window.
    private func tone(amplitude: Float = 0.5, seconds: Double = 10) -> PCMBuffer {
        let frames = Int(48_000 * seconds)
        var ch = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            ch[i] = amplitude * Float(sin(2 * Double.pi * 1000 * Double(i) / 48_000))
        }
        return PCMBuffer(sampleRate: 48_000, channels: [ch, ch])
    }

    func testFullAnalysisFieldsAreMappedThrough() {
        let pcm = tone()
        let full = FullAnalysis.run(pcm)
        let result = AnalyzePipeline.run(pcm)

        XCTAssertEqual(result.bpm, full.bpm)
        XCTAssertEqual(result.key?.camelot.code, full.key?.camelot.code)
        XCTAssertEqual(result.beatGrid?.beatSamples, full.beatGrid?.beatSamples)
        XCTAssertEqual(result.downbeats, full.downbeats)
        XCTAssertEqual(result.phraseCount, full.phraseCount)
        XCTAssertEqual(result.waveformLevels, full.waveformLevels)
        XCTAssertEqual(result.hopSeconds, full.hopSeconds)
        XCTAssertEqual(result.energy, full.energy?.scalar)
        XCTAssertEqual(result.energyCurve, full.energy?.curve ?? [Float]())
    }

    func testLoudnessShimPopulatesReplayGainAndDynamicRange() {
        let result = AnalyzePipeline.run(tone(amplitude: 0.25))
        guard let loudness = result.loudness else { return XCTFail("expected loudness") }

        XCTAssertEqual(loudness.version, AnalysisVersions.loudness)
        guard let lufs = loudness.integratedLUFS, let gain = loudness.replayGainDB else {
            return XCTFail("expected integrated loudness + replay gain")
        }
        // replayGainDB is the gain to the −18 LUFS DJ-headroom target.
        XCTAssertEqual(gain, -18 - lufs, accuracy: 0.001)
        // Crest factor: true peak − overall RMS, strictly positive for a tone.
        XCTAssertNotNil(loudness.dynamicRangeDB)
        XCTAssertGreaterThan(loudness.dynamicRangeDB ?? -1, 0)
        XCTAssertNotNil(loudness.loudnessRangeLU)
    }

    func testSilenceLeavesLoudnessFieldsNil() {
        let silence = PCMBuffer(sampleRate: 48_000,
                                channels: [[Float](repeating: 0, count: 48_000 * 4)])
        let loudness = AnalyzePipeline.run(silence).loudness
        XCTAssertNil(loudness?.integratedLUFS)
        XCTAssertNil(loudness?.replayGainDB)
        XCTAssertNil(loudness?.dynamicRangeDB)
    }

    func testRunIsDeterministic() {
        let a = AnalyzePipeline.run(tone())
        let b = AnalyzePipeline.run(tone())
        XCTAssertEqual(a.bpm, b.bpm)
        XCTAssertEqual(a.loudness?.integratedLUFS, b.loudness?.integratedLUFS)
        XCTAssertEqual(a.loudness?.dynamicRangeDB, b.loudness?.dynamicRangeDB)
        XCTAssertEqual(a.energyCurve, b.energyCurve)
        XCTAssertEqual(a.waveform?.levels.count, b.waveform?.levels.count)
    }
}
