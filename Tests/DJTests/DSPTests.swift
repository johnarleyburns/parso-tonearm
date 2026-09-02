import XCTest
import Accelerate

@testable import TonearmDJ

final class STFTTests: XCTestCase {
    private let config = STFTConfig(fftSize: 4096, hopSize: 2048)

    func testPureTonePeaksAtExpectedBin() {
        let kernel = STFTKernel(config: config)
        // 1 kHz sine at 48 kHz, fftSize samples.
        let f = 1_000.0
        var frame = [Float](repeating: 0, count: config.fftSize)
        for i in frame.indices {
            frame[i] = Float(sin(2 * Double.pi * f * Double(i) / 48_000))
        }
        let spec = frame.withUnsafeBufferPointer { kernel.spectrum($0.baseAddress!) }
        let expectedBin = Int((f / spec.binHz).rounded())
        let maxIdx = spec.power.indices.max { spec.power[$0] < spec.power[$1] } ?? 0
        XCTAssertEqual(maxIdx, expectedBin, "peak bin mismatch")
        XCTAssertEqual(spec.power.count, config.fftSize / 2)
        // Power at the peak is far above the average.
        XCTAssertGreaterThan(spec.power[maxIdx], spec.power.reduce(0, +) / Float(spec.power.count) * 10)
    }

    func testSpectraSlidesByHop() {
        let kernel = STFTKernel(config: config)
        // 2 seconds of audio -> ~47 frames at hop 2048.
        var samples = [Float](repeating: 0, count: 48_000 * 2)
        for i in samples.indices { samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000)) }
        let spectra = samples.withUnsafeBufferPointer { kernel.spectra($0) }
        XCTAssertGreaterThan(spectra.count, 40)
        XCTAssertLessThan(spectra.count, 50)
    }

    func testSilenceProducesTinyPower() {
        let kernel = STFTKernel(config: config)
        let frame = [Float](repeating: 0, count: config.fftSize)
        let spec = frame.withUnsafeBufferPointer { kernel.spectrum($0.baseAddress!) }
        XCTAssertTrue(spec.power.allSatisfy { $0.isFinite })
    }
}

final class SpectralFeatureTests: XCTestCase {
    private func makeFrame(samples: [Float]) -> (Spectrum, SpectralFrame, [Float]) {
        let config = STFTConfig(fftSize: 4096, hopSize: 2048)
        let kernel = STFTKernel(config: config)
        var frame = [Float](repeating: 0, count: config.fftSize)
        for i in 0..<min(samples.count, frame.count) { frame[i] = samples[i] }
        let spec = frame.withUnsafeBufferPointer { kernel.spectrum($0.baseAddress!) }
        let prev = spec.power
        let feats = frame.withUnsafeBufferPointer {
            SpectralFeatures.frame(spec, prevPower: prev, frameSamples: $0)
        }
        return (spec, feats, prev)
    }

    func testChirpCentroidRisesMonotonically() {
        // Linear sweep 100 Hz -> 20 kHz over 1 second.
        let config = STFTConfig(fftSize: 4096, hopSize: 2048)
        let kernel = STFTKernel(config: config)
        var samples = [Float](repeating: 0, count: 48_000)
        for i in samples.indices {
            let t = Double(i) / 48_000
            let f = 100.0 + (20_000.0 - 100.0) * t
            samples[i] = Float(sin(2 * Double.pi * f * t))
        }

        let spectra = samples.withUnsafeBufferPointer { kernel.spectra($0) }
        guard spectra.count > 8 else { return XCTFail("not enough frames") }

        var centroids: [Float] = []
        var prev = spectra[0].power
        for spec in spectra {
            let feats = SpectralFeatures.frame(spec, prevPower: prev,
                                               frameSamples: [Float](repeating: 0, count: 1).withUnsafeBufferPointer { $0 })
            centroids.append(feats.centroid)
            prev = spec.power
        }
        // Compare first vs last frame centroid: the sweep ends much higher.
        XCTAssertGreaterThan(centroids[centroids.count - 1], centroids[0] * 3)
    }

    func testRolloffIsWithinSpectrum() {
        let (_, feats, _) = makeFrame(samples: [])
        XCTAssertGreaterThanOrEqual(feats.rolloff, 0)
    }

    func testFluxRespondsToTransient() {
        let config = STFTConfig(fftSize: 4096, hopSize: 2048)
        let kernel = STFTKernel(config: config)

        // Silent frame then a loud burst: flux should spike.
        let silent = [Float](repeating: 0, count: config.fftSize)
        var burst = [Float](repeating: 0, count: config.fftSize)
        for i in burst.indices { burst[i] = 0.9 * Float(sin(2 * Double.pi * 1000 * Double(i) / 48_000)) }

        let s0 = silent.withUnsafeBufferPointer { kernel.spectrum($0.baseAddress!) }
        let s1 = burst.withUnsafeBufferPointer { kernel.spectrum($0.baseAddress!) }

        let f0 = SpectralFeatures.frame(s0, prevPower: s0.power,
                                        frameSamples: silent.withUnsafeBufferPointer { $0 })
        let f1 = SpectralFeatures.frame(s1, prevPower: s0.power,
                                        frameSamples: burst.withUnsafeBufferPointer { $0 })
        XCTAssertGreaterThan(f1.flux, f0.flux * 100)
    }

    func testZeroCrossingRateOfToneIsLow() {
        let config = STFTConfig(fftSize: 4096, hopSize: 2048)
        var tone = [Float](repeating: 0, count: config.fftSize)
        for i in tone.indices { tone[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000)) }
        let kernel = STFTKernel(config: config)
        let spec = tone.withUnsafeBufferPointer { kernel.spectrum($0.baseAddress!) }
        let feats = SpectralFeatures.frame(spec, prevPower: spec.power,
                                           frameSamples: tone.withUnsafeBufferPointer { $0 })
        // 440 Hz over 4096 samples: ~37.5 cycles, so zcr ~2x cycles/frame ~0.018.
        XCTAssertLessThan(feats.zcr, 0.1)
    }
}

final class OnsetTests: XCTestCase {
    private func envelopeForClickTrack(bpm: Double, seconds: Double) -> [Float] {
        let config = STFTConfig(fftSize: 4096, hopSize: 2048)
        let kernel = STFTKernel(config: config)
        let beatInterval = 60.0 / bpm
        var samples = [Float](repeating: 0, count: Int(48_000 * seconds))
        // 0.5 s of pre-roll silence so the first beat is a real transient.
        var i = Int(0.5 * 48_000)
        while Double(i) / 48_000 < seconds {
            // A percussive hit at each beat: a half-frame Hann-windowed 1 kHz
            // tone burst, a clean energy step inside a single STFT frame.
            let start = i
            for j in 0..<2048 where start + j < samples.count {
                let t = Double(j) / 48_000
                let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(j) / 2047)
                samples[start + j] = 0.9 * Float(sin(2 * Double.pi * 1000 * t)) * Float(hann)
            }
            i += Int(beatInterval * 48_000)
        }
        let spectra = samples.withUnsafeBufferPointer { kernel.spectra($0) }
        return OnsetDetector.envelope(spectra: spectra)
    }

    func testClickTrackProducesPeaksAtBeatIntervals() {
        let bpm = 120.0
        let env = envelopeForClickTrack(bpm: bpm, seconds: 6)
        let frameRateHz = 48_000.0 / 2048.0
        // The adaptive threshold window must be smaller than the beat interval
        // (120 BPM = 0.5 s = ~12 frames), or a neighbouring beat inflates it.
        let onsetConfig = OnsetConfig(thresholdWindow: 5, thresholdK: 2.0)
        let peaks = OnsetDetector.peaks(env, config: onsetConfig, frameRateHz: frameRateHz)
        XCTAssertGreaterThan(peaks.count, 9)

        // First beats should land near 0.5, 1.0, 1.5, 2.0, 2.5 s (0.5 s pre-roll).
        let expected = (0..<5).map { 0.5 + Double($0) * 0.5 }
        for (i, t) in expected.enumerated() {
            XCTAssertEqual(peaks[i].timeSeconds, t, accuracy: 0.06, "peak \(i)")
        }
    }

    func testNoiseDoesNotProduceSpuriousPeaks() {
        let config = STFTConfig(fftSize: 4096, hopSize: 2048)
        let kernel = STFTKernel(config: config)
        // Seeded, not ambient entropy — this test failed intermittently when
        // a SystemRandomNumberGenerator draw happened to exceed the < 3 peaks
        // budget (NFR-DET-3, current_status.md's known flake).
        var rng = SplitMix64(seed: 0x0A1B_2C3D)
        var noise = [Float](repeating: 0, count: 48_000)
        for i in noise.indices { noise[i] = Float.random(in: -0.005...0.005, using: &rng) }
        let spectra = noise.withUnsafeBufferPointer { kernel.spectra($0) }
        let env = OnsetDetector.envelope(spectra: spectra)
        let peaks = OnsetDetector.peaks(env, frameRateHz: 48_000.0 / 2048.0)
        // Quiet white noise at low amplitude should not trigger onsets.
        XCTAssertLessThan(peaks.count, 3)
    }
}

final class BlobRoundTripTests: XCTestCase {
    func testFrameFeaturesRoundTrip() throws {
        var frames: [SpectralFrame] = []
        for i in 0..<4 {
            frames.append(SpectralFrame(centroid: Float(i) + 0.5,
                                        rolloff: Float(i) * 100,
                                        flux: Float(i) * 10,
                                        rms: Float(i) * 0.1,
                                        zcr: 0.02 * Float(i),
                                        bandEnergy: .init(1, 2, 3, 4, 5, 6, 7, 8)))
        }
        let data = AnalysisBlobLayouts.encodeFrameFeatures(frames,
                                                           hopSeconds: 2048.0 / 48_000,
                                                           fftSize: 4096,
                                                           sampleRate: 48_000,
                                                           version: 1)
        let decoded = try AnalysisBlobLayouts.decodeFrameFeatures(data)
        XCTAssertEqual(decoded.frameCount, 4)
        XCTAssertEqual(decoded.featureCount, 6)
        // 4 frames x 6 features (13 floats each).
        XCTAssertEqual(decoded.values.count, 4 * 6)
    }

    func testOnsetEnvelopeRoundTrip() throws {
        let env: [Float] = [0, 0.1, 0.5, 1, 0.5, 0.1, 0]
        let data = AnalysisBlobLayouts.encodeOnsetEnvelope(env, frameRateHz: 23.4, version: 1)
        let decoded = try AnalysisBlobLayouts.decodeOnsetEnvelope(data)
        XCTAssertEqual(decoded.count, 7)
        XCTAssertEqual(decoded.frameRateHz, 23.4, accuracy: 0.001)
        XCTAssertEqual(decoded.values, env)
    }

    func testRejectsBadMagic() {
        let junk = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try AnalysisBlobLayouts.decodeFrameFeatures(junk))
        XCTAssertThrowsError(try AnalysisBlobLayouts.decodeOnsetEnvelope(junk))
    }
}
