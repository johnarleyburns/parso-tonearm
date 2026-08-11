import XCTest

@testable import TonearmDJ

final class PreprocessTests: XCTestCase {

    /// The real model's spec with the bundled filterbank (fixture copy).
    private func realSpec() throws -> EmbeddingModelSpec {
        let filterBank = try EmbeddingModelSpec.loadMelFilterBank(
            from: DJFixtures.url("mel_filterbank_slaney_64", ext: "bin"))
        XCTAssertEqual(filterBank.count, 513 * 64)
        return EmbeddingModelSpec.musicCLAP(melFilterBank: filterBank)
    }

    private func pcmBuffer(from samples: [Float], rate: Double = 48_000) -> PCMBuffer {
        PCMBuffer(sampleRate: rate, channels: [samples])
    }

    // MARK: - Golden log-mel

    func testGoldenLogMelMatchesReferenceFrontend() throws {
        let spec = try realSpec()
        let waveform = DJFixtures.floats("synth_pcm_f32")
        let golden = DJFixtures.floats("synth_logmel_golden_f32")

        let windows = try Preprocess.logMel(pcm: pcmBuffer(from: waveform), spec: spec)
        XCTAssertEqual(windows.count, 1, "2.5 s track -> a single repeat-padded window")
        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.frames, 1_001)
        XCTAssertEqual(window.melBins, 64)
        XCTAssertEqual(window.logMel.count, golden.count)

        // Same-format values: max abs difference across every (frame, bin). The
        // reference computes its STFT via a float32 conv1d DFT rather than vDSP's
        // FFT, so a small worst-case dB gap is expected; 0.5 dB is a tight bound
        // on that cross-implementation difference.
        var maxDiff: Float = 0
        for (i, expected) in golden.enumerated() {
            maxDiff = max(maxDiff, abs(window.logMel[i] - expected))
        }
        XCTAssertLessThanOrEqual(maxDiff, 0.5,
                                 "log-mel diverges from the model's own frontend by \(maxDiff) dB")
    }

    // MARK: - Determinism (NFR-DET-3)

    func testLogMelIsDeterministic() throws {
        let spec = try realSpec()
        let waveform = DJFixtures.floats("synth_pcm_f32")
        let first = try Preprocess.logMel(pcm: pcmBuffer(from: waveform), spec: spec)
        let second = try Preprocess.logMel(pcm: pcmBuffer(from: waveform), spec: spec)
        XCTAssertEqual(first, second, "same input twice -> byte-identical output")
        XCTAssertEqual(Array(try XCTUnwrap(first.first).logMel),
                       Array(try XCTUnwrap(second.first).logMel))
    }

    func testSilenceProducesFlooredLogMel() throws {
        let spec = try realSpec()
        let silence = [Float](repeating: 0, count: 120_000)
        let windows = try Preprocess.logMel(pcm: pcmBuffer(from: silence), spec: spec)
        let window = try XCTUnwrap(windows.first)
        // All-silent -> clamped to 10*log10(1e-10) == -100 dB exactly.
        XCTAssertTrue(window.logMel.allSatisfy { $0 == -100 })
    }

    // MARK: - Windowing (§27.3)

    func testWindowRangesShortTrackSingleWindow() {
        let ranges = Preprocess.windowRanges(count: 120_000, window: 480_000,
                                             hop: 240_000, maxWindows: 240)
        XCTAssertEqual(ranges, [0..<120_000])
    }

    func testWindowRangesThirtySecondTrack() {
        // 30 s at 48k -> windows at 0, 5, 10, 15, 20, 25 s; no partial tail.
        let ranges = Preprocess.windowRanges(count: 1_440_000, window: 480_000,
                                             hop: 240_000, maxWindows: 240)
        XCTAssertEqual(ranges.map(\.lowerBound), [0, 240_000, 480_000, 720_000, 960_000, 1_200_000])
        XCTAssertEqual(ranges.map(\.upperBound), [480_000, 720_000, 960_000, 1_200_000, 1_440_000, 1_440_000])
    }

    func testWindowRangesDropsRedundantTail() {
        // 10.1 s: window at 10 s would cover 0.1 s of new material < hop -> dropped.
        let ranges = Preprocess.windowRanges(count: 484_800, window: 480_000,
                                             hop: 240_000, maxWindows: 240)
        XCTAssertEqual(ranges.map(\.lowerBound), [0, 240_000])
    }

    func testWindowRangesCapUniformSubsampling() {
        // 200 s of audio -> 40 windows, subsampled uniformly to 4 (first and last kept).
        let ranges = Preprocess.windowRanges(count: 480_000 * 20, window: 480_000,
                                             hop: 240_000, maxWindows: 4)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(ranges.map(\.lowerBound), [0, 3_120_000, 6_240_000, 9_360_000])
    }

    /// Window N+1 starts `hop` samples later, i.e. 500 mel frames; interior frames
    /// must align bit-for-bit (same underlying samples through the same vDSP path).
    /// The bound excludes frames that reach a window's reflect-pad tail (the last
    /// frame of every window mirrors its own end).
    func testWindowsAlignByHop() throws {
        let spec = try realSpec()
        var samples = [Float](repeating: 0, count: 1_440_000)   // 30 s
        for i in samples.indices {
            let t = Double(i) / 48_000
            samples[i] = Float(0.5 * sin(2 * .pi * 55 * t) + 0.3 * sin(2 * .pi * 440 * t))
        }
        let windows = try Preprocess.logMel(pcm: pcmBuffer(from: samples), spec: spec)
        XCTAssertEqual(windows.count, 6)
        XCTAssertEqual(windows[1].startSample - windows[0].startSample, 240_000)

        let w0 = try XCTUnwrap(windows[0]).logMel
        let w1 = try XCTUnwrap(windows[1]).logMel
        let shift = Int(spec.hopSeconds * spec.sampleRate) / spec.hopSize
        XCTAssertEqual(shift, 500)
        // Interior frames only: exclude the first two (window start reflect pad)
        // and the last two (window end reflect tail) of the earlier window.
        for frame in 2..<(spec.frames - shift - 2) {
            XCTAssertEqual(Array(w1[frame * 64..<(frame + 1) * 64]),
                           Array(w0[(frame + shift) * 64..<(frame + shift + 1) * 64]))
        }
    }
}
