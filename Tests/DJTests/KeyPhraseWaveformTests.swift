import XCTest
import Accelerate

@testable import TonearmDJ

// MARK: - Key detection

final class KeyTests: XCTestCase {

    private func chromaFor(frequencies: [Double], seconds: Double) -> [HPCP] {
        let config = STFTConfig(fftSize: 4096, hopSize: 2048)
        let kernel = STFTKernel(config: config)
        let n = Int(48_000 * seconds)
        var samples = [Float](repeating: 0, count: n)
        for i in samples.indices {
            var v: Float = 0
            for f in frequencies {
                v += Float(sin(2 * Double.pi * f * Double(i) / 48_000))
            }
            samples[i] = v
        }
        let spectra = samples.withUnsafeBufferPointer { kernel.spectra($0) }
        return spectra.map { KeyDetector.chroma($0) }
    }

    func testPureToneDetectsPitchClass() {
        // A440 -> pitch class 9 (A).
        let frames = chromaFor(frequencies: [440], seconds: 2)
        let estimate = KeyDetector.estimate(frames)
        XCTAssertEqual(estimate?.tonic, 9)
        XCTAssertEqual(estimate?.camelot.letter, "B")   // major mode (A major)
        XCTAssertEqual(estimate?.musicalKey, "A major")
    }

    func testTwoToneMajorChordDetectsKey() {
        // A major: A + C♯ + E with octave reinforcement (higher register so the
        // fundamentals are well above the FFT bin leakage at low frequencies).
        let frames = chromaFor(frequencies: [220, 440, 880, 277.18, 554.37, 329.63, 659.25],
                               seconds: 2)
        let estimate = KeyDetector.estimate(frames)
        XCTAssertEqual(estimate?.tonic, 9)
        XCTAssertEqual(estimate?.isMinor, false)
        XCTAssertEqual(estimate?.camelot.code, "11B")   // A major
        XCTAssertEqual(estimate?.musicalKey, "A major")
    }

    func testConfidenceOrdering() {
        // A root-reinforced major chord is far more confident than a muddy pair
        // of unrelated tones.
        let clear = chromaFor(frequencies: [220, 440, 880, 277.18, 554.37, 329.63, 659.25],
                              seconds: 2)  // A major
        let muddy = chromaFor(frequencies: [220, 311.13, 415.3], seconds: 2)   // no clear key
        let clearEst = KeyDetector.estimate(clear)
        let muddyEst = KeyDetector.estimate(muddy)
        XCTAssertGreaterThan(clearEst?.confidence ?? 0, muddyEst?.confidence ?? 1)
    }

    func testHPCPNormalization() {
        var h = HPCP()
        h[0] = 2
        h[3] = 6
        h.normalize()
        XCTAssertEqual(h.sum, 1, accuracy: 1e-5)
    }
}

// MARK: - Camelot

final class CamelotTests: XCTestCase {

    func testTonicModeTableExact() {
        XCTAssertEqual(Camelot.from(tonic: 0, isMinor: false)?.code, "8B")    // C major
        XCTAssertEqual(Camelot.from(tonic: 9, isMinor: true)?.code, "8A")     // A minor
        XCTAssertEqual(Camelot.from(tonic: 8, isMinor: true)?.code, "1A")     // A♭ minor
        XCTAssertEqual(Camelot.from(tonic: 6, isMinor: false)?.code, "2B")    // F♯ major
        XCTAssertEqual(Camelot.from(tonic: 11, isMinor: true)?.code, "10A")   // B minor
    }

    func testCompatibilitySet() {
        // 8A: same, 7A, 9A, and 8B (relative major).
        let key = CamelotKey(number: 8, letter: "A")
        let compatible = Camelot.compatible(key)
        XCTAssertTrue(compatible.contains(CamelotKey(number: 8, letter: "A")))
        XCTAssertTrue(compatible.contains(CamelotKey(number: 7, letter: "A")))
        XCTAssertTrue(compatible.contains(CamelotKey(number: 9, letter: "A")))
        XCTAssertTrue(compatible.contains(CamelotKey(number: 8, letter: "B")))
        XCTAssertFalse(compatible.contains(CamelotKey(number: 5, letter: "A")))
    }

    func testCompatibilityGrading() {
        let a = CamelotKey(number: 8, letter: "A")
        XCTAssertEqual(Camelot.compatibility(a, CamelotKey(number: 8, letter: "A")), 1.0)
        XCTAssertEqual(Camelot.compatibility(a, CamelotKey(number: 8, letter: "B")), 0.9)
        XCTAssertEqual(Camelot.compatibility(a, CamelotKey(number: 7, letter: "A")), 0.7)
        XCTAssertEqual(Camelot.compatibility(a, CamelotKey(number: 5, letter: "A")), 0.0)
    }
}

// MARK: - Energy

final class EnergyTests: XCTestCase {

    private func frames(rms: [Float]) -> [SpectralFrame] {
        rms.map { SpectralFrame(rms: $0) }
    }

    func testAmplitudeRampRises() {
        // RMS ramps 0.1 -> 1.0 over 32 beats.
        let rms = (0..<32).map { Float($0 + 1) / 32.0 }
        let beats = (0..<32).map { Int64($0 * 12_000) }   // 0.25 s per beat
        let curve = EnergyAnalyzer.curve(frames: frames(rms: rms),
                                         beatSamples: beats,
                                         frameRateHz: 4, sampleRate: 48_000)
        XCTAssertEqual(curve.count, 32)
        XCTAssertTrue(curve.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertLessThan(curve.first ?? 0, curve.last ?? 1)
    }

    func testSilenceIsZero() {
        let beats = (0..<8).map { Int64($0 * 12_000) }
        let curve = EnergyAnalyzer.curve(frames: frames(rms: [Float](repeating: 0, count: 8)),
                                         beatSamples: beats,
                                         frameRateHz: 4, sampleRate: 48_000)
        XCTAssertEqual(curve.reduce(0, +), 0, accuracy: 1e-4)
        XCTAssertEqual(EnergyAnalyzer.scalar(curve), 0)
    }

    func testScalarScale() {
        let curve = [Float](repeating: 0.8, count: 16)
        XCTAssertEqual(EnergyAnalyzer.scalar(curve), 8, accuracy: 0.01)
    }
}

// MARK: - Waveform

final class WaveformTests: XCTestCase {

    func testSilenceIsFlat() {
        let samples = [Float](repeating: 0, count: 48_000 * 2)
        samples.withUnsafeBufferPointer { buf in
            let pyramid = WaveformPyramidBuilder.build(buf, sampleRate: 48_000)
            XCTAssertFalse(pyramid.levels.isEmpty)
            let level0 = pyramid.levels[0]
            XCTAssertTrue(level0.allSatisfy { abs($0.max - 0) < 1e-4 && abs($0.min - 0) < 1e-4 })
            XCTAssertGreaterThan(pyramid.levels.count, 1)
            // Coarser levels shrink.
            XCTAssertLessThan(pyramid.levels.last!.count, level0.count)
        }
    }

    func testSineMinMaxSymmetric() {
        var samples = [Float](repeating: 0, count: 48_000 * 1)
        for i in samples.indices {
            samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000))
        }
        samples.withUnsafeBufferPointer { buf in
            let pyramid = WaveformPyramidBuilder.build(buf, sampleRate: 48_000)
            let level0 = pyramid.levels[0]
            // Envelope is symmetric: min ≈ −max per bin.
            for bin in level0.prefix(20) {
                XCTAssertEqual(bin.min, -bin.max, accuracy: 1e-3)
            }
            XCTAssertGreaterThan(level0.first?.max ?? 0, 0.5)
        }
    }

    func testWaveformBlobRoundTrip() {
        var samples = [Float](repeating: 0, count: 48_000)
        for i in samples.indices {
            samples[i] = Float(sin(2 * Double.pi * 1000 * Double(i) / 48_000))
        }
        let pyramid = samples.withUnsafeBufferPointer {
            WaveformPyramidBuilder.build($0, sampleRate: 48_000)
        }
        let data = AnalysisBlobLayouts.encodeWaveformPyramid(pyramid, version: 1)
        let decoded = try! AnalysisBlobLayouts.decodeWaveformPyramid(data)
        XCTAssertEqual(decoded.levels.count, pyramid.levels.count)
        XCTAssertEqual(decoded.baseSamplesPerBin, pyramid.baseSamplesPerBin)
        XCTAssertEqual(decoded.levels[0].count, pyramid.levels[0].count)
        XCTAssertEqual(decoded.levels[0][0].rms, pyramid.levels[0][0].rms, accuracy: 1e-6)
    }

    func testEnergyCurveBlobRoundTrip() {
        let curve: [Float] = [0.1, 0.4, 0.9, 0.8, 0.2]
        let data = AnalysisBlobLayouts.encodeEnergyCurve(curve, hopSeconds: 0.0427, version: 1)
        let decoded = try! AnalysisBlobLayouts.decodeEnergyCurve(data)
        XCTAssertEqual(decoded.count, curve.count)
        XCTAssertEqual(decoded.values, curve)
    }
}

// MARK: - Phrase

final class PhraseTests: XCTestCase {

    /// Synthetic intro -> drop -> outro: 48 beats, low/high/low energy with
    /// distinct harmony per section so self-similarity novelty is meaningful.
    private func makeFeatures() -> [BeatFeature] {
        var intro = HPCP()
        intro[0] = 0.8; intro[4] = 0.2; intro[7] = 0.1
        intro.normalize()
        var drop = HPCP()
        drop[0] = 0.5; drop[4] = 0.3; drop[7] = 0.4
        drop.normalize()
        var outro = HPCP()
        outro[0] = 0.7; outro[3] = 0.3; outro[10] = 0.2
        outro.normalize()

        var features: [BeatFeature] = []
        for beat in 0..<48 {
            let energy: Float = beat < 16 ? 0.1 : (beat < 32 ? 0.9 : 0.1)
            let chroma: HPCP = beat < 16 ? intro : (beat < 32 ? drop : outro)
            features.append(BeatFeature(chroma: chroma, energy: energy))
        }
        return features
    }

    func testIntroDropOutroBoundaries() {
        let features = makeFeatures()
        let beats = (0..<48).map { Int64($0 * 12_000) }
        // Downbeats every 4 beats.
        let downbeats = Array(stride(from: 0, to: 48, by: 4))
        let phrases = PhraseSegmenter.segment(features: features, beats: beats,
                                              downbeats: downbeats, sampleRate: 48_000)
        XCTAssertFalse(phrases.isEmpty)
        XCTAssertEqual(phrases.first?.type, .intro)
        XCTAssertEqual(phrases.last?.type, .outro)
        // Boundaries land on downbeats (multiples of 4).
        for p in phrases {
            XCTAssertEqual(p.startBeat % 4, 0, "boundary \(p.startBeat) not on a downbeat")
            XCTAssertGreaterThanOrEqual(p.lengthBeats, 4)
        }
        // Energy is bar-aligned: lengths are multiples of 4 beats.
        for p in phrases {
            XCTAssertEqual(p.lengthBeats % 4, 0, "length \(p.lengthBeats) not bar-aligned")
        }
    }

    func testPhraseEnergyValues() {
        let features = makeFeatures()
        let beats = (0..<48).map { Int64($0 * 12_000) }
        let downbeats = Array(stride(from: 0, to: 48, by: 4))
        let phrases = PhraseSegmenter.segment(features: features, beats: beats,
                                              downbeats: downbeats, sampleRate: 48_000)
        XCTAssertFalse(phrases.isEmpty)
        XCTAssertTrue(phrases.allSatisfy { $0.energy >= 0 && $0.energy <= 10 })
        XCTAssertTrue(phrases.allSatisfy { $0.confidence >= 0 && $0.confidence <= 1 })
    }
}

// MARK: - Golden regression

final class GoldenKeyPhraseWaveformTests: XCTestCase {

    /// Golden literals for deterministic pipeline stages (NFR-DET-3, §47.4).
    /// Synthetic fixtures only — no checked-in audio, no network.
    func testGoldenKeyAChord() {
        let config = STFTConfig(fftSize: 4096, hopSize: 2048)
        let kernel = STFTKernel(config: config)
        var samples = [Float](repeating: 0, count: 48_000 * 2)
        let freqs: [Double] = [220, 440, 880, 277.18, 554.37, 329.63, 659.25]
        for i in samples.indices {
            var v: Float = 0
            for f in freqs { v += Float(sin(2 * Double.pi * f * Double(i) / 48_000)) }
            samples[i] = v
        }
        let spectra = samples.withUnsafeBufferPointer { kernel.spectra($0) }
        let chroma = spectra.map { KeyDetector.chroma($0) }
        let estimate = KeyDetector.estimate(chroma)
        XCTAssertEqual(estimate?.camelot.code, "11B")      // A major
        XCTAssertEqual(estimate?.tonic, 9)
        XCTAssertEqual(estimate?.isMinor, false)
        XCTAssertTrue(estimate?.confidence ?? 0 > 0.5)
    }

    func testGoldenEnergySilence() {
        let samples = [Float](repeating: 0, count: 48_000)
        let (env, _) = SyntheticAudio.onsetEnvelope(from: samples)
        // Envelope of pure silence is ~0.
        XCTAssertTrue(env.allSatisfy { abs($0) < 1e-4 })
    }

    func testGoldenWaveformPyramidShape() {
        var samples = [Float](repeating: 0, count: 48_000)
        for i in samples.indices {
            samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000))
        }
        let pyramid = samples.withUnsafeBufferPointer {
            WaveformPyramidBuilder.build($0, sampleRate: 48_000)
        }
        XCTAssertEqual(pyramid.levels.first?.count, Int(ceil(48_000.0 / 256.0)))
        XCTAssertEqual(pyramid.baseSamplesPerBin, 256)
    }
}
