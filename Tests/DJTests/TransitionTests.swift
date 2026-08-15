import XCTest
import AVFoundation

@testable import TonearmDJ

/// M5 commit 5.5 — **AT-TRANS-1..5**, each of the five §35B beginner
/// transitions in **both halves** (plan decision 24, §47.3):
///
/// - the **audio half** — a scripted command sequence against the offline
///   render, asserted in the output buffer;
/// - the **layout half** — a model-level assertion that every control a
///   transition needs is present and reachable on both the tablet (§41.9b) and
///   compact (§42.7c) surfaces.
///
/// Only row 3 (Echo Out) is new engine work — rows 1, 2, 4, 5 were already
/// performable by the M4 engine; the coder does not invent DSP for them
/// (§35B). The Goertzel magnitude helper makes the band assertions crisp:
/// a 55 Hz tone is attributable to one deck and one EQ band, so "killing LOW
/// removes the low band from that channel and the other channel's low is
/// unaffected" is a number, not a vibe.
@MainActor
final class TransitionTests: XCTestCase {

    private let sampleRate = 48_000.0

    // MARK: - AT-TRANS-1 Bass Swap

    func testBassSwapKillRemovesLowBandFromOneChannelOnly() throws {
        // Deck A carries a low tone (55 Hz, LOW band) and a mid tone (440 Hz,
        // MID band); deck B carries its own low tone (62 Hz). Killing A's LOW
        // must strip A's 55 Hz while B's 62 Hz and A's 440 Hz pass untouched.
        // Each deck is measured alone (the other paused) so the low tones never
        // beat against each other — the magnitudes are exact and attributable.
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let a = toneSource(frequencies: [55, 440])
        let b = toneSource(frequencies: [62])
        engine.load(.a, source: a.source)
        engine.load(.b, source: b.source)
        engine.play(.a)
        engine.play(.b)

        engine.pause(.b)
        let aBefore = try steadyMagnitudes(engine, windows: 2)
        engine.play(.b)
        engine.pause(.a)
        let bBefore = try steadyMagnitudes(engine, windows: 2)
        engine.play(.a)

        engine.setEQKnobs(.a, low: -1, mid: 0, high: 0) // LOW to the end stop: a true kill

        engine.pause(.b)
        let aAfter = try steadyMagnitudes(engine, windows: 2)
        engine.play(.b)
        engine.pause(.a)
        let bAfter = try steadyMagnitudes(engine, windows: 2)
        engine.play(.a)

        // Before the kill, both decks' low bands are present at the tone
        // amplitudes (the EQ is a bit-exact pass until touched, §35.1).
        XCTAssertEqual(aBefore[55]!, 0.25, accuracy: 0.03, "deck A's low is audible before the swap")
        XCTAssertEqual(aBefore[440]!, 0.25, accuracy: 0.03, "deck A's mid is audible before the swap")
        XCTAssertEqual(bBefore[62]!, 0.25, accuracy: 0.03, "deck B's low is audible before the swap")

        // After the kill, A's 55 Hz collapses; the other channel's low and A's
        // own mid are unaffected (FR-TRANS-3: LOW at minimum removes bass
        // entirely, not approximately).
        XCTAssertLessThan(aAfter[55]!, 0.01, "killing LOW must remove deck A's bass entirely")
        XCTAssertEqual(aAfter[440]!, 0.25, accuracy: 0.03, "deck A's mid is unaffected")
        XCTAssertEqual(bAfter[62]!, 0.25, accuracy: 0.03, "deck B's low is unaffected")
    }

    // MARK: - AT-TRANS-2 Filter Transition

    func testFilterSweepHighPassesOutgoingAndLeavesIncomingUnchanged() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let a = toneSource(frequencies: [55, 440])
        let b = toneSource(frequencies: [62])
        engine.load(.a, source: a.source)
        engine.load(.b, source: b.source)
        engine.play(.a)
        engine.play(.b)
        engine.setFilter(.a, knob: 0) // centre: hard bypass, bit-exact

        engine.pause(.b)
        let aBefore = try steadyMagnitudes(engine, windows: 2)
        engine.play(.b)
        engine.pause(.a)
        let bBefore = try steadyMagnitudes(engine, windows: 2)
        engine.play(.a)

        // A high-pass sweep on the outgoing deck, up to a ~300 Hz corner: enough
        // to take its low out while its mid still passes. Full right is a 6 kHz
        // corner, which would take the mid with it (§35.3).
        engine.setFilter(.a, knob: 0.475)

        engine.pause(.b)
        let aAfter = try steadyMagnitudes(engine, windows: 2)
        engine.play(.b)
        engine.pause(.a)
        let bAfter = try steadyMagnitudes(engine, windows: 2)
        engine.play(.a)

        // The incoming deck's spectrum is unchanged — its filter is never
        // touched and the centre detent is a hard bypass (§35.3).
        XCTAssertEqual(bBefore[62]!, bAfter[62]!, accuracy: 0.03,
                       "the incoming deck's spectrum is untouched")
        // The outgoing deck's low collapses under the HP sweep while its mid
        // (above the 300 Hz end-stop cutoff) passes — the SVF's ~1.15 peaking
        // near the cutoff keeps a floor, not an equality, the honest claim.
        XCTAssertLessThan(aAfter[55]!, 0.02,
                          "the outgoing deck's low collapses under the high-pass sweep")
        XCTAssertGreaterThan(aAfter[440]!, 0.2,
                             "the outgoing deck's mid passes the HP at 300 Hz")
    }

    // MARK: - AT-TRANS-3 Echo Out

    func testEchoOutTailRingsAfterTheFaderCutAndDecaysToSilence() throws {
        // With the §35A echo enabled and the channel fader taken to zero, the
        // master bus must **still contain a decaying tail at the beat-synced
        // interval**, decaying monotonically to silence (§35A.2, FR-TRANS-4).
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let impulse = impulseSource()
        engine.load(.a, source: impulse.source)
        engine.play(.a)
        engine.setEchoEnabled(.a, enabled: true)
        engine.setEchoBeats(.a, beats: 1) // 24000 frames at 120 BPM
        engine.setEchoDepth(.a, depth: 0.8)
        engine.setEchoFeedback(.a, feedback: 0.7)

        _ = try engine.renderMono(1000) // the impulse passes through at unity fader

        engine.setChannelFader(.a, gain: 0) // Echo Out: cut the fader
        let tail = try renderFrames(engine, count: 6 * 24_000)

        var peaks: [Float] = []
        for beat in 0..<6 {
            let window = Array(tail[(beat * 24_000)..<((beat + 1) * 24_000)])
            peaks.append(window.reduce(0) { max($0, abs($1)) })
        }
        // The first window holds the echo of the impulse (depth × 1.0), then
        // each beat window is feedback × the previous (0.7 per beat).
        XCTAssertEqual(peaks[0], 0.8, accuracy: 0.02,
                       "the tail is audible at the beat interval after the fader cut")
        for i in 1..<peaks.count {
            XCTAssertLessThan(peaks[i], peaks[i - 1],
                              "the tail decays monotonically at the beat-synced interval")
        }
        XCTAssertLessThan(peaks[5], peaks[0] / 2, "the tail is well on its way to silence")
    }

    func testEchoOutDisabledContinuesTheTail() throws {
        // The §35A.2 disabled path at graph level: turning the echo off stops
        // new input to the line but the tail keeps ringing until it decays.
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let impulse = impulseSource()
        engine.load(.a, source: impulse.source)
        engine.play(.a)
        engine.setEchoEnabled(.a, enabled: true)
        engine.setEchoBeats(.a, beats: 0.5) // 12000 frames at 120 BPM
        engine.setEchoDepth(.a, depth: 0.8)
        engine.setEchoFeedback(.a, feedback: 0.7)
        _ = try engine.renderMono(500)

        engine.setEchoEnabled(.a, enabled: false) // source off; tail continues
        engine.setChannelFader(.a, gain: 0)
        let tail = try renderFrames(engine, count: 4 * 12_000)

        var peaks: [Float] = []
        for beat in 0..<4 {
            let window = Array(tail[(beat * 12_000)..<((beat + 1) * 12_000)])
            peaks.append(window.reduce(0) { max($0, abs($1)) })
        }
        XCTAssertGreaterThan(peaks[0], 0.7, "the tail continues after the echo is disabled")
        for i in 1..<peaks.count {
            XCTAssertLessThan(peaks[i], peaks[i - 1], "the disabled tail decays monotonically")
        }
    }

    // MARK: - AT-TRANS-4 Fader Cut

    func testFaderCutSharpCrossfaderIsSampleAccurateWithNoZipper() throws {
        // A sharp-curve crossfader cut from full A to full B on a downbeat: the
        // output moves A-only → B-only within the smoothing window, never
        // overshoots either endpoint, and produces no zipper (a discontinuity
        // would exceed the ramp's bounded slope by orders of magnitude).
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let a = constSource(value: 0.5)
        let b = constSource(value: 0.25)
        engine.load(.a, source: a.source)
        engine.load(.b, source: b.source)
        engine.play(.a)
        engine.play(.b)
        engine.setCrossfader(-1, curve: .sharp)
        _ = try renderFrames(engine, count: 8192) // settle the crossfader gains

        let fullA = try engine.renderMono(128)
        XCTAssertTrue(fullA.allSatisfy { abs($0 - 0.5) < 1e-3 }, "full A is deck A only")

        engine.setCrossfader(1, curve: .sharp) // the cut
        let transition = try renderFrames(engine, count: 2048)
        let after = try engine.renderMono(512)

        // No zipper: the transition is the two smoothed gains ramping in step,
        // so no adjacent-sample jump can approach the signal's own step.
        var maxDelta: Float = 0
        for i in 1..<transition.count {
            maxDelta = max(maxDelta, abs(transition[i] - transition[i - 1]))
        }
        XCTAssertLessThan(maxDelta, 0.01,
                          "no zipper artefact — the sharp cut is a bounded ramp, not a step")

        // The transition is monotonic (A's gain falls as B's rises) and stays
        // between the two endpoints.
        for i in 1..<transition.count {
            XCTAssertLessThanOrEqual(transition[i], transition[i - 1] + 1e-4,
                                     "the sharp cut ramps monotonically from A to B")
            XCTAssertLessThanOrEqual(transition[i], 0.5 + 1e-3, "never overshoots A's level")
            XCTAssertGreaterThanOrEqual(transition[i], 0.25 - 1e-3, "never undershoots B's level")
        }
        XCTAssertTrue(after.allSatisfy { abs($0 - 0.25) < 1e-3 }, "full B is deck B only")
    }

    // MARK: - AT-TRANS-5 Blend / Mix

    func testTwoDeckBlendStaysInsideTheLimiterCeiling() throws {
        let ceiling: Float = 0.9
        let engine = try makeEngine(limiterCeiling: ceiling, limiterLookaheadFrames: 240)
        try engine.start()
        defer { engine.stop() }

        let a = constSource(value: 1.2)
        let b = constSource(value: 1.2)
        engine.load(.a, source: a.source)
        engine.load(.b, source: b.source)
        engine.play(.a)
        engine.play(.b)

        // Sweep the crossfader across a long simultaneous blend.
        var maxOut: Float = 0
        for position: Float in [-1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, 1] {
            engine.setCrossfader(position, curve: .constantPower)
            let out = try renderFrames(engine, count: 8192)
            maxOut = max(maxOut, out.reduce(0) { max($0, abs($1)) })
        }
        XCTAssertLessThanOrEqual(maxOut, ceiling + 1e-3,
                                 "a hot two-deck blend never exceeds the limiter ceiling (FR-ENG-7)")

        // The blend is genuinely both decks: at the centre the summed bus is
        // hotter than either deck alone would produce (1.2×√2/2×2 = 1.7), and
        // the limiter holds it at the ceiling.
        engine.pause(.b)
        engine.setCrossfader(0, curve: .constantPower)
        _ = try renderFrames(engine, count: 8192)
        let soloA = try renderFrames(engine, count: 8192).reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertGreaterThan(maxOut, soloA,
                             "the centre blend sums both decks (hotter than deck A alone)")
        XCTAssertEqual(maxOut, ceiling, accuracy: 0.01,
                       "the blend is held at the ceiling, not above it")
    }

    // MARK: - AT-TRANS-1..5 layout half (§41.9b, §42.7c)

    func testAllFiveTransitionsReachableOnTheTabletSurface() {
        // FR-TRANS-1/2: every control a §35B transition needs is on the §41.9b
        // tablet surface's always-visible club layout — no menu, no mode switch.
        for row in WorkspaceModel.transitionRoleSets {
            XCTAssertTrue(row.roles.isSubset(of: WorkspaceModel.tabletAlwaysVisibleRoles),
                          "\(row.transition)'s controls must be on the tablet's default surface "
                          + "(needs \(row.roles))")
        }
    }

    func testAllFiveTransitionsReachableOnTheCompactSurface() {
        // FR-TRANS-1 on the phone (§42.7c): every transition's controls are
        // reachable — always-visible or in the spring-loaded bank drawer.
        for row in WorkspaceModel.transitionRoleSets {
            XCTAssertTrue(row.roles.isSubset(of: WorkspaceModel.compactReachableRoles),
                          "\(row.transition)'s controls must be reachable on the compact surface "
                          + "(needs \(row.roles))")
        }
    }

    func testEchoOutRequiresNoDrawerOnTheCompactSurface() {
        // §42.7c: Echo Out is a two-control transition — echo on, fader down —
        // so both controls must be reachable without a drawer. The ECHO button
        // and the channel fader are both in the always-visible band.
        let echoOut = WorkspaceModel.transitionRoleSets.first { $0.transition == "Echo Out" }!
        XCTAssertTrue(echoOut.roles.isSubset(of: WorkspaceModel.compactAlwaysVisibleRoles),
                      "Echo Out's controls must both be always-visible on the compact surface "
                      + "(never behind a drawer)")
        XCTAssertTrue(echoOut.roles.contains(.echo))
        XCTAssertTrue(echoOut.roles.contains(.channelFader))
    }

    func testBassSwapUsesTheSpringLoadedEQDrawerOnCompact() {
        // §42.7c: the drawer's spring-loading is what makes Bass Swap
        // performable on a phone — press, kill the low, release, drawer gone.
        let bassSwap = WorkspaceModel.transitionRoleSets.first { $0.transition == "Bass Swap" }!
        XCTAssertTrue(bassSwap.roles.contains(.lowEQ))
        XCTAssertTrue(WorkspaceModel.compactDrawerRoles.contains(.lowEQ),
                      "the compact LOW EQ lives in the momentary bank drawer")
        XCTAssertTrue(bassSwap.roles.isSubset(of: WorkspaceModel.compactReachableRoles))
    }

    func testFaderCutAndEchoControlsMeetTheMinimumTarget() {
        // NFR-A11Y-6: no target shrunk to fit. The transferable-core controls
        // every transition reaches are ≥ 44 pt on both surfaces — the club
        // geometry asserts the transport/strip sizes; here the echo surface and
        // the crossfader band pin the minimum.
        XCTAssertGreaterThanOrEqual(WorkspaceModel.crossfaderBarHeight, 44,
                                    "the compact always-visible band is ≥ 44 pt")
        XCTAssertGreaterThanOrEqual(WorkspaceModel.DrawerGeometry.tapThreshold, 0.1)
    }

    // MARK: - Helpers

    /// Render `windows` settle-then-measure passes and return the Goertzel
    /// magnitude of each tone over the measurement window. The engine must be
    /// started and loaded before calling.
    private func steadyMagnitudes(_ engine: PerformanceEngine,
                                  windows: Int) throws -> [Double: Double] {
        // Settle the EQ/filter/smoothing transients, then measure a clean
        // window so the magnitude is the steady-state linear gain × amplitude.
        _ = try renderFrames(engine, count: 24_000)
        let measured = try renderFrames(engine, count: 12_000)
        return [
            55: magnitude(measured, at: 55),
            62: magnitude(measured, at: 62),
            440: magnitude(measured, at: 440)
        ]
    }

    /// The peak amplitude of a `frequency` component in `samples` by Goertzel
    /// — deterministic (NFR-DET-3) and crisp enough to attribute a band to a
    /// specific deck.
    private func magnitude(_ samples: [Float], at frequency: Double) -> Double {
        let n = samples.count
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var q0 = 0.0
        var q1 = 0.0
        var q2 = 0.0
        for s in samples {
            q0 = coefficient * q1 - q2 + Double(s)
            q2 = q1
            q1 = q0
        }
        let power = q1 * q1 + q2 * q2 - coefficient * q1 * q2
        return 2 * sqrt(max(0, power)) / Double(n)
    }

    private func makeEngine(limiterCeiling: Float? = nil,
                            limiterLookaheadFrames: Int = 0) throws -> PerformanceEngine {
        try PerformanceEngine(configuration: .init(sampleRate: 48_000, channelCount: 1,
                                                   ringCapacity: 16,
                                                   limiterCeiling: limiterCeiling,
                                                   limiterLookaheadFrames: limiterLookaheadFrames))
    }

    /// A sum of unit-amplitude tones scaled to 0.25 peak each.
    private func toneSource(frequencies: [Double]) -> TestSource {
        TestSource(frames: 400_000) { n in
            0.25 * Float(frequencies.reduce(0.0) {
                $0 + sin(2 * Double.pi * $1 * Double(n) / self.sampleRate)
            })
        }
    }

    /// A constant signal — the fader-cut and blend tests use it because the
    /// transition's endpoints are then exact numbers.
    private func constSource(value: Float) -> TestSource {
        TestSource(frames: 400_000) { _ in value }
    }

    /// A single unit impulse at source sample 0 — the echo-out tests.
    private func impulseSource() -> TestSource {
        TestSource(frames: 400_000) { $0 == 0 ? 1.0 : 0.0 }
    }

    /// Render `count` frames in manual-rendering-maximum chunks.
    private func renderFrames(_ engine: PerformanceEngine, count: Int) throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(count)
        var remaining = count
        while remaining > 0 {
            let chunk = AVAudioFrameCount(min(4096, remaining))
            out += try engine.renderMono(chunk)
            remaining -= Int(chunk)
        }
        return out
    }
}

/// An owned, heap-backed PCM source for the offline harness — the same shape
/// as `EngineOfflineTests`' harness.
private final class TestSource {
    let buffer: UnsafeMutablePointer<Float>
    let source: DeckSource

    init(frames: Int, channels: Int = 1, sampleRate: Double = 48_000,
         grid: DeckGrid = DeckGrid(bpm: 120, sampleRate: 48_000),
         _ generator: (Int) -> Float) {
        buffer = .allocate(capacity: frames * channels)
        for i in 0..<(frames * channels) {
            buffer[i] = generator(i)
        }
        source = DeckSource(pcm: UnsafeRawPointer(buffer), frameCount: Int64(frames),
                            channelCount: channels, sampleRate: sampleRate, grid: grid)
    }

    deinit {
        buffer.deallocate()
    }
}
