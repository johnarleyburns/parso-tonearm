import Foundation
import Testing
@testable import TonearmCore

/// W1 — Pro Audio: the settings value drives the DSP, the DSP nulls when
/// transparent and audibly changes the signal when a stage is active, and the
/// realtime kernel matches the offline math.
@Suite struct ProAudioSettingsTests {

    private func testFrames(count: Int = 4096, sampleRate: Double = 48_000) -> [(Double, Double)] {
        (0..<count).map { i in
            let t = Double(i) / sampleRate
            let l = 0.5 * sin(2 * .pi * 1_000 * t) + 0.3 * sin(2 * .pi * 8_000 * t)
            let r = 0.4 * sin(2 * .pi * 500 * t)
            return (l, r)
        }
    }

    // MARK: - Settings value

    @Test func testDefaultSettingsAreTransparent() {
        #expect(ProAudioSettings.default.isTransparent)
    }

    @Test func testActiveParametricBandBreaksTransparency() {
        var settings = ProAudioSettings.default
        settings.parametricBands = [
            ParametricEQBand(type: .peaking, frequency: 1_000, gainDB: 6, q: 1)
        ]
        #expect(!settings.isTransparent)
    }

    @Test func testEnabledCrossfeedBreaksTransparency() {
        var settings = ProAudioSettings.default
        settings.crossfeedEnabled = true
        settings.crossfeedDB = -6
        #expect(!settings.isTransparent)
    }

    @Test func testConvolutionTapsAreCappedForRealtimeSafety() {
        var settings = ProAudioSettings.default
        settings.convolutionTaps = 100_000
        #expect(settings.convolutionImpulseResponse.count == ProAudioSettings.maxConvolutionTaps)
        #expect(!settings.convolutionPlan().isTransparent)
    }

    @Test func testCodableRoundTrip() throws {
        var settings = ProAudioSettings.default
        settings.parametricBands = [
            ParametricEQBand(id: "b1", type: .lowShelf, frequency: 120, gainDB: 3, q: 0.7)
        ]
        settings.crossfeedEnabled = true
        settings.convolutionTaps = 128
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ProAudioSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func testPersistenceRoundTripsThroughUserDefaults() {
        let defaults = UserDefaults(suiteName: "ProAudioSettingsTests")!
        defaults.removePersistentDomain(forName: "ProAudioSettingsTests")
        var settings = ProAudioSettings.default
        settings.crossfeedEnabled = true
        settings.convolutionTaps = 64
        ProAudioSettingsPersistence.save(settings, defaults: defaults)
        #expect(ProAudioSettingsPersistence.load(defaults: defaults) == settings)
    }

    // MARK: - Bit-perfect plan honesty

    @Test func testBitPerfectAvailableOnlyWhenTransparentAndRatesMatch() {
        let settings = ProAudioSettings.default
        let clean = settings.bitPerfectPlan(
            hardwareSampleRate: 48_000, sourceSampleRate: 48_000, replayGainActive: false)
        #expect(clean.canUseBitPerfect)
        #expect(clean.blockers == [])

        let mismatch = settings.bitPerfectPlan(
            hardwareSampleRate: 48_000, sourceSampleRate: 44_100, replayGainActive: false)
        #expect(!mismatch.canUseBitPerfect)
        #expect(mismatch.blockers == [.sampleRateMismatch])
    }

    @Test func testBitPerfectBlockedByActiveStages() {
        var settings = ProAudioSettings.default
        settings.parametricBands = [
            ParametricEQBand(type: .peaking, frequency: 1_000, gainDB: 4, q: 1)
        ]
        settings.crossfeedEnabled = true
        let plan = settings.bitPerfectPlan(
            hardwareSampleRate: 48_000, sourceSampleRate: 48_000, replayGainActive: true)
        #expect(!plan.canUseBitPerfect)
        #expect(plan.blockers.contains(.parametricEQ))
        #expect(plan.blockers.contains(.crossfeed))
        #expect(plan.blockers.contains(.replayGain))
    }

    // MARK: - Kernel DSP

    @Test func testTransparentKernelIsBitExactPassthrough() {
        var kernel = ProAudioKernel(
            eqGains: Array(repeating: 0, count: EQEngine.bandCount),
            eqBypassed: false,
            settings: .default,
            replayGain: 1)
        #expect(kernel.isTransparent)
        let input = testFrames()
        let output = kernel.renderStereo(input)
        for (a, b) in zip(input, output) {
            #expect(a.0 == b.0)
            #expect(a.1 == b.1)
        }
    }

    @Test func testParametricBandAudiblyChangesSignal() {
        var settings = ProAudioSettings.default
        settings.parametricBands = [
            ParametricEQBand(type: .peaking, frequency: 1_000, gainDB: 9, q: 1)
        ]
        var kernel = ProAudioKernel(
            eqGains: Array(repeating: 0, count: EQEngine.bandCount),
            eqBypassed: false,
            settings: settings,
            replayGain: 1)
        #expect(!kernel.isTransparent)
        let input = testFrames()
        let output = kernel.renderStereo(input)
        var maxDiff = 0.0
        for (a, b) in zip(input, output) { maxDiff = max(maxDiff, abs(a.0 - b.0)) }
        #expect(maxDiff > 0.001, "a +9 dB parametric band must change the signal")
    }

    @Test func testCrossfeedMixesChannels() {
        var settings = ProAudioSettings.default
        settings.crossfeedEnabled = true
        settings.crossfeedDB = -6
        var kernel = ProAudioKernel(
            eqGains: Array(repeating: 0, count: EQEngine.bandCount),
            eqBypassed: false,
            settings: settings,
            replayGain: 1)
        // Hard-panned left input should leak into the right output.
        let out = kernel.processStereo(left: 1, right: 0, stereo: true)
        #expect(out.right > 0.001, "crossfeed must bleed L into R")
        #expect(out.left < 1.0, "crossfeed attenuates the direct channel")
    }

    @Test func testConvolutionChangesSignal() {
        var settings = ProAudioSettings.default
        settings.convolutionTaps = 64
        var kernel = ProAudioKernel(
            eqGains: Array(repeating: 0, count: EQEngine.bandCount),
            eqBypassed: false,
            settings: settings,
            replayGain: 1)
        #expect(!kernel.isTransparent)
        let input = testFrames()
        let output = kernel.renderStereo(input)
        var maxDiff = 0.0
        for (a, b) in zip(input, output) { maxDiff = max(maxDiff, abs(a.0 - b.0)) }
        #expect(maxDiff > 0.001, "a 64-tap low-pass must change the signal")
    }

    @Test func testReplayGainScalesSignal() {
        var kernel = ProAudioKernel(
            eqGains: Array(repeating: 0, count: EQEngine.bandCount),
            eqBypassed: false,
            settings: .default,
            replayGain: 0.5)
        #expect(!kernel.isTransparent)
        let out = kernel.processStereo(left: 1, right: -1, stereo: true)
        #expect(abs((out.left) - (0.5)) <= 1e-9)
        #expect(abs((out.right) - (-0.5)) <= 1e-9)
    }

    @Test func testMonoSkipsCrossfeedButStillEQs() {
        var settings = ProAudioSettings.default
        settings.crossfeedEnabled = true
        settings.crossfeedDB = -6
        var kernel = ProAudioKernel(
            eqGains: Array(repeating: 0, count: EQEngine.bandCount),
            eqBypassed: false,
            settings: settings,
            replayGain: 0.5)
        let out = kernel.processStereo(left: 1, right: 0, stereo: false)
        // Mono path leaves right untouched (no crossfeed) and scales left by RG.
        #expect(out.right == 0)
        #expect(abs((out.left) - (0.5)) <= 1e-9)
    }
}
