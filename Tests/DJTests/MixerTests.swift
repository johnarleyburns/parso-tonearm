import XCTest

@testable import TonearmDJ

/// Commit 4.4 — the pure mixer DSP kernels (§35): the Linkwitz–Riley 3-band
/// EQ, the state-variable sweep filter, the crossfader laws, the smoothed
/// gains and the master lookahead limiter. These are the deterministic,
/// golden kernels; the graph wiring over them is exercised in
/// `EngineOfflineTests`.
final class MixerTests: XCTestCase {

    // MARK: - Crossfader laws (§35.4)

    func testConstantPowerCrossfaderEndpointsAndPowerIdentity() {
        let fullA = crossfaderGains(-1, .constantPower)
        XCTAssertEqual(fullA.a, 1, accuracy: 1e-6)
        XCTAssertEqual(fullA.b, 0, accuracy: 1e-6)

        let fullB = crossfaderGains(1, .constantPower)
        XCTAssertEqual(fullB.a, 0, accuracy: 1e-6)
        XCTAssertEqual(fullB.b, 1, accuracy: 1e-6)

        let center = crossfaderGains(0, .constantPower)
        XCTAssertEqual(center.a, cos(Float.pi / 4), accuracy: 1e-6)
        XCTAssertEqual(center.b, sin(Float.pi / 4), accuracy: 1e-6)

        for step in 0...100 {
            let x = -1 + Float(step) / 50
            let g = crossfaderGains(x, .constantPower)
            XCTAssertEqual(g.a * g.a + g.b * g.b, 1, accuracy: 1e-5,
                           "constant-power blend keeps power constant at x = \(x)")
        }
    }

    func testLinearCrossfaderSumsToUnity() {
        for step in 0...100 {
            let x = -1 + Float(step) / 50
            let g = crossfaderGains(x, .linear)
            XCTAssertEqual(g.a + g.b, 1, accuracy: 1e-6)
            XCTAssertEqual(g.a, (1 - x) * 0.5, accuracy: 1e-6)
            XCTAssertEqual(g.b, (x + 1) * 0.5, accuracy: 1e-6)
        }
    }

    func testSharpCrossfaderCutsWithSmallOverlap() {
        XCTAssertEqual(crossfaderGains(-1, .sharp).a, 1)
        XCTAssertEqual(crossfaderGains(1, .sharp).b, 1)
        XCTAssertEqual(crossfaderGains(0, .sharp).a, 1)
        XCTAssertEqual(crossfaderGains(0, .sharp).b, 1)
        XCTAssertEqual(crossfaderGains(0.5, .sharp).a, 0)
        XCTAssertEqual(crossfaderGains(0.5, .sharp).b, 1)
        XCTAssertEqual(crossfaderGains(-0.5, .sharp).a, 1)
        XCTAssertEqual(crossfaderGains(-0.5, .sharp).b, 0)
    }

    // MARK: - Smoothed gain

    func testSmoothedGainRampsToTargetWithoutOvershoot() {
        var gain = SmoothedGain(value: 0, timeConstantMillis: 5, sampleRate: 48_000)
        gain.target = 1
        var previous: Float = 0
        var reached = false
        for _ in 0..<4096 {
            let value = gain.next()
            XCTAssertLessThanOrEqual(value, 1, "a one-pole ramp never overshoots its target")
            XCTAssertGreaterThanOrEqual(value, previous, "a one-pole ramp is monotonic")
            if value > 0.9 { reached = true }
            previous = value
        }
        XCTAssertTrue(reached)
        XCTAssertEqual(previous, 1, accuracy: 0.001)
    }

    // MARK: - 3-band EQ (§35.2)

    func testEQUnityIsMagnitudeFlat() {
        // The LR4's unity sum is an all-pass: magnitude-flat across the whole
        // spectrum, not bit-identical (§35.2 "flat magnitude at unity"). Measure
        // the steady-state linear gain at tones in every band.
        var eq = ThreeBandEQ(sampleRate: 48_000)
        eq.setGains(low: 1, mid: 1, high: 1)
        for hz in [100.0, 400.0, 1_000.0, 4_000.0, 12_000.0] {
            let gain = steadyEQGain(&eq, toneHz: hz)
            XCTAssertEqual(gain, 1, accuracy: 0.02, "unity EQ is flat at \(hz) Hz")
        }
    }

    func testEQFullKillIsSilence() {
        var eq = ThreeBandEQ(sampleRate: 48_000)
        eq.setGains(low: 0, mid: 0, high: 0)
        for _ in 0..<8192 { _ = eq.process(mixedSignal(0)) } // let the ramps settle
        var maxAbs: Float = 0
        for n in 0..<2048 {
            maxAbs = max(maxAbs, abs(eq.process(mixedSignal(n))))
        }
        XCTAssertLessThan(maxAbs, 1e-4, "a full EQ kill must be −∞")
    }

    func testEQLowKillRemovesLowBand() {
        var eq = ThreeBandEQ(sampleRate: 48_000)
        eq.setGains(low: 0, mid: 1, high: 1)
        for _ in 0..<8192 { _ = eq.process(0) } // let the ramps settle
        var maxAbs: Float = 0
        for n in 0..<2048 {
            // 55 Hz sits two octaves below the 200 Hz crossover.
            let x = 0.5 * Float(sin(2 * Double.pi * 55 * Double(n) / 48_000))
            let y = eq.process(x)
            if n >= 1000 { maxAbs = max(maxAbs, abs(y)) } // skip the ring-up transient
        }
        XCTAssertLessThan(maxAbs, 0.02, "killing the low band must strip a pure low tone")
    }

    func testKnobToGainAnchors() {
        XCTAssertEqual(ThreeBandEQ.knobToGain(0), 1, "12 o'clock is unity")
        XCTAssertEqual(ThreeBandEQ.knobToGain(1), powf(10, 6 / 20), accuracy: 1e-6,
                       "full right is a +6 dB boost")
        XCTAssertEqual(ThreeBandEQ.knobToGain(-1), 0, "full left is a hard kill")
        XCTAssertLessThan(ThreeBandEQ.knobToGain(-0.5), 1)
        XCTAssertGreaterThan(ThreeBandEQ.knobToGain(0.5), 1)
    }

    // MARK: - Sweep filter (§35.3)

    func testFilterCentreIsHardBypass() {
        var filter = SweepFilter(sampleRate: 48_000)
        filter.setKnob(0)
        for n in 0..<1024 {
            let x = mixedSignal(n)
            XCTAssertEqual(filter.process(x), x, "the centre detent must be a hard bypass")
        }
    }

    func testFilterLowPassPassesLowAndAttenuatesHigh() {
        var lp = SweepFilter(sampleRate: 48_000)
        lp.setKnob(-1)
        let lowGain = steadyGain(of: &lp, toneHz: 100)
        let highGain = steadyGain(of: &lp, toneHz: 8_000)
        XCTAssertEqual(lowGain, 1, accuracy: 0.2, "LP at 300 Hz passes a 100 Hz tone")
        XCTAssertLessThan(highGain, 0.1, "LP at 300 Hz kills an 8 kHz tone")
    }

    func testFilterHighPassAttenuatesLowAndPassesHigh() {
        var hp = SweepFilter(sampleRate: 48_000)
        // The 300 Hz corner now sits partway up the high-pass side, because the
        // sweep runs from transparent at the centre detent to maximum at the
        // extreme (§35.3) rather than the other way round.
        hp.setKnob(0.475)
        let lowGain = steadyGain(of: &hp, toneHz: 100)
        let highGain = steadyGain(of: &hp, toneHz: 8_000)
        XCTAssertLessThan(lowGain, 0.2, "HP at 300 Hz strongly attenuates a 100 Hz tone")
        XCTAssertEqual(highGain, 1, accuracy: 0.2, "HP at 300 Hz passes an 8 kHz tone")
    }

    /// §35.3: neutral at the centre detent, maximum effect at each extreme.
    /// The two sides sweep in opposite directions — a transparent low-pass sits
    /// above the band and a transparent high-pass sits below it — and the knob
    /// must get *more* filtered the further it travels, on both sides.
    func testFilterCutoffMappingEndpoints() {
        // Low-pass side: 12 kHz (through) at centre, 300 Hz (dark) at full left.
        XCTAssertEqual(SweepFilter.cutoffHz(forKnob: -1), SweepFilter.minCutoffHz, accuracy: 1e-4)
        XCTAssertGreaterThan(SweepFilter.cutoffHz(forKnob: -0.1), 1_000,
                             "just off centre the low-pass is near-transparent")
        // High-pass side: 20 Hz (through) at centre, 6 kHz (only the top) full
        // right — the far end is held inside the SVF's stable range.
        XCTAssertEqual(SweepFilter.cutoffHz(forKnob: 1), SweepFilter.hpMaxCutoffHz, accuracy: 1e-4)
        XCTAssertLessThan(SweepFilter.cutoffHz(forKnob: 0.1), 100,
                          "just off centre the high-pass is near-transparent")
        // Monotonic in both directions: further out is always more filtering.
        XCTAssertLessThan(SweepFilter.cutoffHz(forKnob: -0.6), SweepFilter.cutoffHz(forKnob: -0.3))
        XCTAssertGreaterThan(SweepFilter.cutoffHz(forKnob: 0.6), SweepFilter.cutoffHz(forKnob: 0.3))
    }

    // MARK: - Master limiter (§35.5)

    func testLimiterNeverExceedsCeiling() {
        let limiter = LookaheadLimiter(ceiling: 0.95, lookaheadFrames: 240, sampleRate: 48_000)
        var maxOut: Float = 0
        for i in 0..<48_000 {
            let x = 1.8 * Float(sin(2 * Double.pi * 220 * Double(i) / 48_000))
            maxOut = max(maxOut, abs(limiter.process(x)))
        }
        XCTAssertLessThanOrEqual(maxOut, 0.95 + 1e-4, "the output must never exceed the ceiling")
        XCTAssertEqual(maxOut, 0.95, accuracy: 0.05, "a hot signal is held at the ceiling")
    }

    func testLimiterDelaysByLookaheadAndPassesQuietSignal() {
        let limiter = LookaheadLimiter(ceiling: 0.95, lookaheadFrames: 240, sampleRate: 48_000)
        var out: [Float] = []
        for _ in 0..<240 { out.append(limiter.process(0.25)) }
        for _ in 0..<240 { out.append(limiter.process(0.25)) }
        XCTAssertTrue(out[0..<240].allSatisfy { $0 == 0 },
                      "the lookahead window primes with silence")
        for i in 240..<480 {
            XCTAssertEqual(out[i], 0.25, accuracy: 1e-4,
                           "a sub-ceiling signal passes at unity after the priming delay")
        }
    }

    func testLimiterCatchesTransientBeforeItReachesOutput() {
        let limiter = LookaheadLimiter(ceiling: 0.95, lookaheadFrames: 240, sampleRate: 48_000)
        for _ in 0..<480 { _ = limiter.process(0.1) }
        var outputs: [Float] = []
        for i in 0..<480 {
            outputs.append(limiter.process(i == 0 ? 2.0 : 0.1))
        }
        XCTAssertEqual(outputs[240], 0.95, accuracy: 0.02,
                       "the 2.0 impulse, delayed by the lookahead, is clamped to the ceiling")
        XCTAssertLessThanOrEqual(outputs[0..<240].max()!, 0.95 + 1e-4,
                                 "gain reduction precedes the transient at the output")
    }

    func testZeroLookaheadLimiterIsBrickwall() {
        let limiter = LookaheadLimiter(ceiling: 0.9, lookaheadFrames: 0, sampleRate: 48_000)
        var maxOut: Float = 0
        for i in 0..<48_000 {
            let x = 1.5 * Float(sin(2 * Double.pi * 440 * Double(i) / 48_000))
            maxOut = max(maxOut, abs(limiter.process(x)))
        }
        XCTAssertLessThanOrEqual(maxOut, 0.9 + 1e-4)
    }

    // MARK: - Helpers

    /// A mix of tones across all three EQ bands (110 Hz low, 440 Hz mid,
    /// 3 kHz/10 kHz high), peak amplitude ~1.0.
    private func mixedSignal(_ n: Int) -> Float {
        let f = Double(n)
        let sum = sin(2 * Double.pi * 110 * f / 48_000)
            + sin(2 * Double.pi * 440 * f / 48_000)
            + sin(2 * Double.pi * 3_000 * f / 48_000)
            + sin(2 * Double.pi * 10_000 * f / 48_000)
        return 0.25 * Float(sum)
    }

    /// The steady-state **linear gain** of `filter` for a unit sine at
    /// `toneHz`, measured over the tail of a 12k-sample run.
    private func steadyGain(of filter: inout SweepFilter, toneHz: Float) -> Float {
        var energy: Float = 0
        var count = 0
        let total = 12_000
        for i in 0..<total {
            let x = Float(sin(2 * Double.pi * Double(toneHz) * Double(i) / 48_000))
            let y = filter.process(x)
            if i >= total - 2_000 {
                energy += y * y
                count += 1
            }
        }
        return (energy / Float(count)).squareRoot() * sqrt(2)
    }

    /// The steady-state **linear gain** of `eq` for a unit sine at `toneHz`.
    private func steadyEQGain(_ eq: inout ThreeBandEQ, toneHz: Double) -> Float {
        var energy: Float = 0
        var count = 0
        let total = 16_000
        for i in 0..<total {
            let x = Float(sin(2 * Double.pi * toneHz * Double(i) / 48_000))
            let y = eq.process(x)
            if i >= total - 2_000 {
                energy += y * y
                count += 1
            }
        }
        return (energy / Float(count)).squareRoot() * sqrt(2)
    }
}
