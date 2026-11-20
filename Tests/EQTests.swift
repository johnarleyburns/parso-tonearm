import Foundation
import Testing
@testable import TonearmCore

/// T4.1 — EQ DSP: bit-transparent bypass (offline render null test), flat is a
/// no-op, and non-flat curves actually change the signal.
@Suite struct EQTests {

    private func testSignal(count: Int = 4096, sampleRate: Double = 48000) -> [Double] {
        (0..<count).map { i in
            let t = Double(i) / sampleRate
            return 0.5 * sin(2 * .pi * 1000 * t) + 0.3 * sin(2 * .pi * 4000 * t)
        }
    }

    // Bypass must be bit-exact: output == input, sample for sample.
    @Test func testBypassIsBitTransparent() {
        var eq = EQEngine(gains: [3, -2, 4, 0, 0, 1, 2, -3, 5, 0], bypassed: true)
        let input = testSignal()
        let output = eq.render(input)
        #expect(output == input)
    }

    // A perfectly flat curve (all 0 dB) is also a no-op.
    @Test func testFlatIsBitTransparent() {
        var eq = EQEngine(gains: Array(repeating: 0, count: EQEngine.bandCount))
        #expect(eq.isTransparent)
        let input = testSignal()
        #expect(eq.render(input) == input)
    }

    // A non-flat curve must actually alter the signal (not a no-op).
    @Test func testNonFlatCurveChangesSignal() {
        var eq = EQEngine(gains: [0, 0, 0, 0, 0, 6, 0, 0, 0, 0])  // +6 dB @ 1 kHz
        let input = testSignal()
        let output = eq.render(input)
        #expect(output.count == input.count)
        var maxDiff = 0.0
        for (a, b) in zip(input, output) { maxDiff = max(maxDiff, abs(a - b)) }
        #expect(maxDiff > 0.001, "a +6 dB band must change the signal")
    }

    // Engaging/disengaging: toggling bypass returns to the exact input again.
    @Test func testDisengageRestoresTransparency() {
        var eq = EQEngine(gains: [5, 5, 5, 5, 5, 5, 5, 5, 5, 5])
        let input = testSignal()
        _ = eq.render(input)      // process while engaged
        eq.reset()
        eq.bypassed = true
        #expect(eq.render(input) == input)
    }

    @Test func testBandFrequenciesAreISO10Band() {
        #expect(EQEngine.bandFrequencies ==
                       [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
    }

    // MARK: - Presets

    @Test func testBuiltInPresets() {
        #expect(EQPreset.builtIns.map { $0.name } ==
                       ["Flat", "Concert Hall", "Spoken", "78 rpm"])
        for preset in EQPreset.builtIns {
            #expect(preset.gains.count == EQEngine.bandCount)
        }
    }

    @Test func testFlatPresetIsAllZero() {
        #expect(EQPreset.flat.gains.allSatisfy { $0 == 0 })
    }
}
