import XCTest

@testable import TonearmDJ

/// M5 commit 5.5 — the §35A post-fader beat-synced echo kernel (plan §5 5.5,
/// spec §35A.2). The pure half (`BeatEcho` control value + delay math) and the
/// render-thread half (`BeatEchoLine` ring DSP) are the deterministic golden
/// kernels; the graph placement is exercised in `TransitionTests` (AT-TRANS-3's
/// audio half).
final class BeatEchoTests: XCTestCase {

    private let sampleRate = 48_000.0

    // MARK: - §35A.2 delay math

    func testDelayFramesDerivedFromBPM() {
        // beats × 60/BPM × sampleRate.
        XCTAssertEqual(BeatEcho.delayFrames(beats: 1, bpm: 120, sampleRate: sampleRate), 24_000,
                       "one beat at 120 BPM is 0.5 s = 24 000 frames")
        XCTAssertEqual(BeatEcho.delayFrames(beats: 0.5, bpm: 120, sampleRate: sampleRate), 12_000)
        XCTAssertEqual(BeatEcho.delayFrames(beats: 4, bpm: 120, sampleRate: sampleRate), 96_000)
        XCTAssertEqual(BeatEcho.delayFrames(beats: 1, bpm: 60, sampleRate: sampleRate), 48_000,
                       "a tempo change moves the echo with it — 60 BPM doubles the delay")
        XCTAssertEqual(BeatEcho.delayFrames(beats: 4, bpm: 60, sampleRate: sampleRate), 192_000)
        XCTAssertEqual(BeatEcho.delayFrames(beats: 4, bpm: BeatEcho.slowestSupportedBPM,
                                            sampleRate: sampleRate),
                       BeatEcho.maxDelayFrames(sampleRate: sampleRate),
                       "the ring is sized for 4 beats at the slowest supported tempo")
    }

    func testDelayFramesWithoutMasterClockFallsBackToNominal() {
        // A missing or zero master clock must not divide by zero on the render
        // thread — the nominal tempo keeps the delay well-defined (§35A.2).
        XCTAssertEqual(BeatEcho.delayFrames(beats: 1, bpm: 0, sampleRate: sampleRate),
                       BeatEcho.delayFrames(beats: 1, bpm: BeatEcho.nominalBPM, sampleRate: sampleRate))
        XCTAssertEqual(BeatEcho.delayFrames(beats: 1, bpm: -5, sampleRate: sampleRate),
                       BeatEcho.delayFrames(beats: 1, bpm: BeatEcho.nominalBPM, sampleRate: sampleRate))
    }

    // MARK: - §35A.2 control clamping

    func testBeatEchoClampsControls() {
        let echo = BeatEcho(beats: 8, depth: 2, feedback: 0.99)
        XCTAssertEqual(echo.beats, 4, "beats clamp to the §35A.2 maximum")
        XCTAssertEqual(echo.depth, 1, "depth clamps to 1")
        XCTAssertEqual(echo.feedback, BeatEcho.maxFeedback, "feedback clamps below unity")
        XCTAssertEqual(BeatEcho.maxFeedback, 0.85, accuracy: 1e-6)

        let low = BeatEcho(beats: 0.05, depth: -1, feedback: -1)
        XCTAssertEqual(low.beats, 0.25, "beats clamp to the §35A.2 minimum (1/4)")
        XCTAssertEqual(low.depth, 0)
        XCTAssertEqual(low.feedback, 0)
    }

    func testFeedbackIsHardClampedBelowUnity() {
        // A self-oscillating echo is a defect, not a feature (§35A.2).
        for requested: Float in [0.86, 0.9, 1.0, 2.0] {
            let echo = BeatEcho(feedback: requested)
            XCTAssertLessThanOrEqual(echo.feedback, BeatEcho.maxFeedback)
            XCTAssertLessThan(echo.feedback, 1, "feedback can never reach unity")
        }
    }

    func testRingCapacityCoversTheSlowestTempo() {
        // The ring is allocated at graph construction and never grows (§12.3),
        // so it must hold the longest supported delay: 4 beats at the slowest
        // supported tempo (the caller allocates + 1, so the maximum delay
        // itself is representable). Every §35A.2 delay fits inside it.
        let capacity = BeatEcho.maxDelayFrames(sampleRate: sampleRate) + 1
        for bpm in stride(from: 55.0, through: 220.0, by: 5.0) {
            for beats in [0.25, 0.5, 1.0, 2.0, 4.0] {
                let frames = BeatEcho.delayFrames(beats: beats, bpm: bpm, sampleRate: sampleRate)
                XCTAssertLessThan(frames, capacity,
                                  "delay \(beats) beats at \(bpm) BPM fits the ring")
            }
        }
    }

    // MARK: - BeatEchoLine DSP

    func testEchoRepeatsAtTheBeatInterval() {
        // A single impulse at sample 0 returns exactly one beat later — the
        // delayed wet read, at the §35A.2 delay length.
        let line = makeLine()
        line.setDelayFrames(24_000)
        line.setParams(BeatEcho(enabled: true, beats: 1, depth: 1, feedback: 0))

        var out = Array(repeating: Float(0), count: 24_002)
        out[0] = line.process(1.0)   // the impulse: dry passes, wet is 0
        for i in 1..<24_002 {
            out[i] = line.process(0)
        }
        XCTAssertEqual(out[0], 1.0, "the dry impulse passes through the post-fader echo")
        for i in 1..<24_000 {
            XCTAssertEqual(out[i], 0, "silence until the delayed read at sample \(i)")
        }
        XCTAssertEqual(out[24_000], 1.0, "the echo returns exactly one beat (24 000 frames) later")
        XCTAssertEqual(out[24_001], 0, "no feedback → no further repeats")
    }

    func testFeedbackMakesTheTailDecayMonotonically() {
        // Feedback re-injects a clamped-below-unity fraction, so each echo is
        // strictly smaller than the last and the tail always decays (§35A.2).
        let line = makeLine()
        line.setDelayFrames(24_000)
        line.setParams(BeatEcho(enabled: true, beats: 1, depth: 0.8, feedback: 0.7))

        _ = line.process(1.0)
        var peaks: [Float] = []
        for _ in 1...5 {
            var peak: Float = 0
            for _ in 0..<24_000 {
                peak = max(peak, abs(line.process(0)))
            }
            peaks.append(peak)
        }
        // Depth × impulse: 0.8, then 0.8×0.7, then 0.8×0.7² …
        XCTAssertEqual(peaks[0], 0.8, accuracy: 1e-4)
        XCTAssertEqual(peaks[1], 0.8 * 0.7, accuracy: 1e-4)
        XCTAssertEqual(peaks[2], 0.8 * 0.7 * 0.7, accuracy: 1e-4)
        for i in 1..<peaks.count {
            XCTAssertLessThan(peaks[i], peaks[i - 1],
                              "the tail decays monotonically at the beat-synced interval")
        }
    }

    func testDelayChangeCrossfadesWithoutDiscontinuity() {
        // Changing the delay must crossfade between read pointers over one
        // buffer, not jump — a pointer jump clicks, and a click during a
        // transition is audible in a way a DJ will not forgive (§35A.2).
        let line = makeLine(crossfadeFrames: 4096)
        line.setDelayFrames(4_800)
        line.setParams(BeatEcho(enabled: true, beats: 0.25, depth: 1, feedback: 0.5))

        var out: [Float] = []
        for i in 0..<24_000 {
            out.append(line.process(0.5 * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))))
        }
        line.setDelayFrames(12_000) // a delay change mid-stream
        for i in 24_000..<48_000 {
            out.append(line.process(0.5 * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))))
        }

        var maxDelta: Float = 0
        for i in 1..<out.count {
            maxDelta = max(maxDelta, abs(out[i] - out[i - 1]))
        }
        // A hard pointer jump would shift the wet to an unrelated sine phase
        // (amplitude ~1.0). The smooth crossfade keeps every sample within the
        // signal's own bounded slope — a few per cent of the amplitude.
        XCTAssertLessThan(maxDelta, 0.15,
                          "the delay change must crossfade, not jump (max delta \(maxDelta))")
    }

    func testDisabledContinuesTailThenBypasses() {
        // enabled = false stops new input to the line but continues to read the
        // tail until it decays below the noise floor, then bypasses entirely at
        // zero cost (§35A.2) — this is what "echo out" means.
        let line = makeLine(crossfadeFrames: 1024)
        line.setDelayFrames(6_000)
        line.setParams(BeatEcho(enabled: true, beats: 0.25, depth: 0.9, feedback: 0.7))
        _ = line.process(1.0)

        line.setParams(BeatEcho(enabled: false, beats: 0.25, depth: 0.9, feedback: 0.7))

        var peaks: [Float] = []
        for _ in 0..<28 {
            var peak: Float = 0
            for _ in 0..<6_000 {
                peak = max(peak, abs(line.process(0)))
            }
            peaks.append(peak)
        }
        XCTAssertGreaterThan(peaks[0], 0.8, "the tail is audible right after the source is removed")
        for i in 1..<peaks.count {
            XCTAssertLessThan(peaks[i], peaks[i - 1],
                              "the tail decays monotonically at the beat-synced interval")
        }
        XCTAssertLessThan(peaks[peaks.count - 1], peaks[0] / 10, "the tail decays toward silence")
        XCTAssertEqual(line.process(0.25), 0.25,
                       "once the tail is gone the line bypasses at zero cost — dry passes bit-exact")
    }

    func testBypassedLinePassesThroughBitExact() {
        let line = makeLine(crossfadeFrames: 512)
        line.setDelayFrames(4_800)
        line.setParams(BeatEcho(enabled: true, beats: 1, depth: 1, feedback: 0.7))
        _ = line.process(1.0)
        line.setParams(BeatEcho(enabled: false, beats: 1, depth: 1, feedback: 0.7))
        // Drain the tail fully below the floor (26 echoes × 4800 + a full
        // delay period of quiet to trigger the bypass), then confirm it.
        for _ in 0..<140_000 { _ = line.process(0) }
        for i in 0..<1_024 {
            let x = Float(i) / 1_024
            XCTAssertEqual(line.process(x), x, "a bypassed line returns the dry sample bit-exact")
        }
    }

    func testReenablingClearsTheBypass() {
        let line = makeLine(crossfadeFrames: 512)
        line.setDelayFrames(4_800)
        line.setParams(BeatEcho(enabled: true, beats: 1, depth: 1, feedback: 0.7))
        _ = line.process(1.0)
        line.setParams(BeatEcho(enabled: false, beats: 1, depth: 1, feedback: 0.7))
        for _ in 0..<140_000 { _ = line.process(0) }
        XCTAssertEqual(line.process(0.25), 0.25, "bypassed")

        line.setParams(BeatEcho(enabled: true, beats: 1, depth: 1, feedback: 0.7))
        _ = line.process(1.0)
        for _ in 0..<4_799 { _ = line.process(0) }
        XCTAssertGreaterThan(abs(line.process(0)), 1e-6,
                             "re-enabling feeds the line again and the wet returns")
    }

    // MARK: - Helpers

    private func makeLine(crossfadeFrames: Int = 4096) -> BeatEchoLine {
        BeatEchoLine(capacity: BeatEcho.maxDelayFrames(sampleRate: sampleRate),
                     sampleRate: sampleRate,
                     crossfadeFrames: crossfadeFrames)
    }
}
