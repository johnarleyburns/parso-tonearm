import XCTest

@testable import TonearmDJ

/// Commit 4.8 — the jog control model and its view seam (plan 4.8; §40.7,
/// FR-ENG-11, AT-TWIN-4).
///
/// Three tiers:
/// - pure `JogGestureModel` tests: contact-relative rotation → `scrub`/`nudge`,
///   the radius split fixed across a boundary-crossing drag, sensitivity
///   scaling (0.5–2.0), release, determinism (§40.7.2–40.7.4);
/// - the `JogTransport` seam: the jog reaches the transport only through the
///   engine's transport intents, and the routing is guarded by the §46.3 shim
///   (AT-TWIN-4);
/// - the detent driver's pure per-beat/per-downbeat decision (§40.7.4).
@MainActor
final class JogGestureModelTests: XCTestCase {

    private let center = JogPoint(x: 0, y: 0)
    private let radius = 100.0

    // MARK: - Region split at touch-down (§40.7.3)

    func testPlatterTouchDownEmitsHold() {
        var model = JogGestureModel()
        let intent = model.touchDown(at: JogPoint(x: 40, y: 0), center: center, radius: radius)
        XCTAssertEqual(intent, .hold, "touch-down on the platter is touch = hold")
        XCTAssertEqual(model.region, .platter)
        XCTAssertTrue(model.isTracking)
    }

    func testRingTouchDownEmitsNothingUntilItRotates() {
        var model = JogGestureModel()
        let down = model.touchDown(at: JogPoint(x: 90, y: 0), center: center, radius: radius)
        XCTAssertNil(down, "the ring is a bend surface — nothing until it rotates")
        XCTAssertEqual(model.region, .ring)
        let move = model.touchMoved(to: JogPoint(x: 0, y: 90))
        XCTAssertEqual(move, .nudge(rate: 0.08), "ring rotation emits the bend intent")
    }

    // MARK: - Rotation → scrub / nudge (§40.7.2)

    func testPlatterRotationEmitsScrubContactRelative() {
        var model = JogGestureModel()
        XCTAssertEqual(model.touchDown(at: JogPoint(x: 40, y: 0), center: center, radius: radius), .hold)
        let quarterTurn = model.touchMoved(to: JogPoint(x: 0, y: 40))
        XCTAssertEqual(quarterTurn, .scrub(radians: .pi / 2),
                       "a quarter turn from touch-down is +π/2 contact-relative")
    }

    func testDisplacementIsMeasuredFromWhereverTheFingerLands() {
        // The same end point reached from different touch-down points reads a
        // different displacement — rotation is contact-relative (§40.7.2).
        var a = JogGestureModel()
        _ = a.touchDown(at: JogPoint(x: 40, y: 0), center: center, radius: radius)
        XCTAssertEqual(a.touchMoved(to: JogPoint(x: 0, y: 40)), .scrub(radians: .pi / 2))

        var b = JogGestureModel()
        _ = b.touchDown(at: JogPoint(x: 0, y: 40), center: center, radius: radius)
        XCTAssertEqual(b.touchMoved(to: JogPoint(x: 40, y: 0)), .scrub(radians: -.pi / 2),
                       "the mirror gesture reads the mirror displacement")
    }

    // MARK: - Radius split is fixed for the gesture (§40.7.3)

    func testDragCrossingTheBoundaryDoesNotChangeMode() {
        // Platter → drag far out into the ring region: still a scrub.
        var platter = JogGestureModel()
        XCTAssertEqual(platter.touchDown(at: JogPoint(x: 40, y: 0), center: center, radius: radius), .hold)
        XCTAssertEqual(platter.region, .platter)
        let out = platter.touchMoved(to: JogPoint(x: 0, y: 95))
        XCTAssertEqual(out, .scrub(radians: .pi / 2),
                       "crossing into the ring must not change the platter mode (§40.7.3)")
        XCTAssertEqual(platter.region, .platter)

        // Ring → drag deep into the platter region: still a nudge.
        var ring = JogGestureModel()
        XCTAssertNil(ring.touchDown(at: JogPoint(x: 90, y: 0), center: center, radius: radius))
        XCTAssertEqual(ring.region, .ring)
        let inWard = ring.touchMoved(to: JogPoint(x: 0, y: 20))
        XCTAssertEqual(inWard, .nudge(rate: 0.08),
                       "crossing into the platter must not change the ring mode (§40.7.3)")
        XCTAssertEqual(ring.region, .ring)
    }

    // MARK: - Sensitivity (§40.7.4)

    func testSensitivityScalesDisplacement() {
        func scrub(at sensitivity: Double) -> JogGestureModel.Intent? {
            var model = JogGestureModel(sensitivity: sensitivity)
            _ = model.touchDown(at: JogPoint(x: 40, y: 0), center: center, radius: radius)
            return model.touchMoved(to: JogPoint(x: 0, y: 40))
        }
        XCTAssertEqual(scrub(at: 1.0), .scrub(radians: .pi / 2))
        XCTAssertEqual(scrub(at: 2.0), .scrub(radians: .pi), "double sensitivity doubles the displacement")
        XCTAssertEqual(scrub(at: 0.5), .scrub(radians: .pi / 4), "half sensitivity halves it")
    }

    func testSensitivityIsClampedToTheRange() {
        XCTAssertEqual(JogGestureModel(sensitivity: 3.0).sensitivity, 2.0)
        XCTAssertEqual(JogGestureModel(sensitivity: 0.1).sensitivity, 0.5)
        XCTAssertEqual(JogGestureModel(sensitivity: 1.0).sensitivity, 1.0)
        XCTAssertEqual(JogGestureModel.sensitivityRange.lowerBound, 0.5)
        XCTAssertEqual(JogGestureModel.sensitivityRange.upperBound, 2.0)
    }

    func testSensitivityScalesTheRingBend() {
        var model = JogGestureModel(sensitivity: 2.0)
        XCTAssertNil(model.touchDown(at: JogPoint(x: 90, y: 0), center: center, radius: radius))
        XCTAssertEqual(model.touchMoved(to: JogPoint(x: 0, y: 90)), .nudge(rate: 0.16),
                       "a quarter turn at 2.0 saturates the ±16% bend")
    }

    // MARK: - Release

    func testReleaseEndsTheGestureAndFurtherMovesAreIgnored() {
        var model = JogGestureModel()
        _ = model.touchDown(at: JogPoint(x: 40, y: 0), center: center, radius: radius)
        XCTAssertEqual(model.touchUp(), .release)
        XCTAssertFalse(model.isTracking)
        XCTAssertNil(model.region)
        XCTAssertEqual(model.displacementRadians, 0)

        XCTAssertNil(model.touchMoved(to: JogPoint(x: 0, y: 40)), "a lifted jog emits nothing")
        XCTAssertNil(model.touchUp(), "a second lift emits nothing")
    }

    func testRingReleaseAlsoEmitsRelease() {
        var model = JogGestureModel()
        _ = model.touchDown(at: JogPoint(x: 90, y: 0), center: center, radius: radius)
        XCTAssertEqual(model.touchUp(), .release, "both regions end with the same lift intent")
    }

    // MARK: - Platter mode (§41.9a: vinyl = scratch, CDJ = nudge, plan 4.11)

    func testVinylModeIsTheDefaultPlatterAction() {
        var model = JogGestureModel()
        XCTAssertEqual(model.jogMode, .vinyl)
        _ = model.touchDown(at: JogPoint(x: 40, y: 0), center: center, radius: radius)
        XCTAssertEqual(model.touchMoved(to: JogPoint(x: 0, y: 40)), .scrub(radians: .pi / 2),
                       "vinyl platter rotation scratches (§40.7.3)")
    }

    func testCDJModePlatterEmitsNudgeNotScrub() {
        var model = JogGestureModel(jogMode: .cdj)
        XCTAssertEqual(model.touchDown(at: JogPoint(x: 40, y: 0), center: center, radius: radius), .hold,
                       "touch = hold in CDJ mode too (§40.7.3)")
        XCTAssertEqual(model.region, .platter)
        XCTAssertEqual(model.touchMoved(to: JogPoint(x: 0, y: 40)),
                       .nudge(rate: JogGestureModel.bendRate(angle: .pi / 2)),
                       "CDJ platter rotation nudges, it does not scrub (§41.9a)")
    }

    func testCDJModeRingStillBends() {
        var model = JogGestureModel(jogMode: .cdj)
        XCTAssertNil(model.touchDown(at: JogPoint(x: 90, y: 0), center: center, radius: radius))
        XCTAssertEqual(model.touchMoved(to: JogPoint(x: 0, y: 90)), .nudge(rate: 0.08),
                       "the ring bend is unchanged in CDJ mode")
    }

    func testCDJPlatterNudgeSaturatesAtTheMaxBend() {
        var model = JogGestureModel(sensitivity: 2.0, jogMode: .cdj)
        _ = model.touchDown(at: JogPoint(x: 40, y: 0), center: center, radius: radius)
        XCTAssertEqual(model.touchMoved(to: JogPoint(x: 0, y: 40)), .nudge(rate: 0.16),
                       "a quarter turn at 2.0 saturates the platter nudge")
    }

    func testSetSensitivityClampsToTheRange() {
        var model = JogGestureModel()
        model.setSensitivity(3.0)
        XCTAssertEqual(model.sensitivity, 2.0, "the mixer column's fader is clamped to §40.7.4")
        model.setSensitivity(0.1)
        XCTAssertEqual(model.sensitivity, 0.5)
        model.setSensitivity(1.4)
        XCTAssertEqual(model.sensitivity, 1.4, accuracy: 1e-12)
    }

    // MARK: - iPad hub readout (§41.9a bar/beat, plan 4.11)

    func testBarBeatReadoutDerivesFromThePlayhead() {
        // 120 BPM at 48 kHz → 24 000 samples per beat; a 4/4 bar → 96 000.
        XCTAssertEqual(JogView.barBeat(playheadSample: 0, bpmEffective: 120, sampleRate: 48_000).bar, 1)
        XCTAssertEqual(JogView.barBeat(playheadSample: 0, bpmEffective: 120, sampleRate: 48_000).beat, 1)
        let beat = Int64(24_000)
        XCTAssertEqual(JogView.barBeat(playheadSample: beat, bpmEffective: 120, sampleRate: 48_000).beat, 2)
        XCTAssertEqual(JogView.barBeat(playheadSample: beat * 3, bpmEffective: 120, sampleRate: 48_000).beat, 4)
        XCTAssertEqual(JogView.barBeat(playheadSample: beat * 4, bpmEffective: 120, sampleRate: 48_000).bar, 2,
                       "the beat after 4 lands in bar 2")
        XCTAssertEqual(JogView.barBeat(playheadSample: beat * 4, bpmEffective: 120, sampleRate: 48_000).beat, 1)
        XCTAssertEqual(JogView.barBeat(playheadSample: beat * 35, bpmEffective: 120, sampleRate: 48_000).bar, 9)
        XCTAssertEqual(JogView.barBeat(playheadSample: -100, bpmEffective: 120, sampleRate: 48_000).bar, 1,
                       "a negative playhead clamps to bar 1")
        XCTAssertEqual(JogView.barBeat(playheadSample: 0, bpmEffective: 0, sampleRate: 48_000).bar, 1,
                       "no tempo reads bar 1, beat 1")
    }

    // MARK: - Determinism

    func testDeterministicScriptMatchesGoldenIntentSequence() {
        var model = JogGestureModel(sensitivity: 1.0)
        var log: [JogGestureModel.Intent] = []

        func record(_ intent: JogGestureModel.Intent?) {
            if let intent { log.append(intent) }
        }

        record(model.touchDown(at: JogPoint(x: 40, y: 0), center: center, radius: radius))
        record(model.touchMoved(to: JogPoint(x: 0, y: 40)))
        record(model.touchMoved(to: JogPoint(x: -40, y: 0)))
        record(model.touchMoved(to: JogPoint(x: 0, y: -40)))
        record(model.touchUp())

        XCTAssertEqual(log, [
            .hold,
            .scrub(radians: .pi / 2),
            .scrub(radians: .pi),
            .scrub(radians: -.pi / 2),
            .release,
        ], "the same touch script must emit the same intents every run")
    }

    // MARK: - Bend saturation

    func testBendSaturatesAtTheMaxRate() {
        XCTAssertEqual(JogGestureModel.bendRate(angle: .pi), JogGestureModel.maxBendRate, accuracy: 1e-12)
        XCTAssertEqual(JogGestureModel.bendRate(angle: 4 * .pi), JogGestureModel.maxBendRate, accuracy: 1e-12,
                       "rotation beyond half a turn cannot over-bend")
        XCTAssertEqual(JogGestureModel.bendRate(angle: -.pi), -JogGestureModel.maxBendRate, accuracy: 1e-12)
        XCTAssertEqual(JogGestureModel.bendRate(angle: 0), 0)
    }

    // MARK: - Pure scrub math (JogTransport)

    func testScrubSamplesPerRadianIsOneBeatPerRevolution() {
        XCTAssertEqual(JogTransport.scrubSamplesPerRadian(bpm: 120, sampleRate: 48_000),
                       Int64(48_000.0 * 60.0 / 120.0 / (2.0 * .pi)))
        XCTAssertEqual(JogTransport.scrubSamplesPerRadian(bpm: 0, sampleRate: 48_000), 0,
                       "no tempo means no scrub mapping")
        XCTAssertEqual(JogTransport.scrubSamplesPerRadian(bpm: 120, sampleRate: 0), 0)
    }

    // MARK: - AT-TWIN-4: no jog code on the render thread (§46.3)

    func testJogTransportIsGuardedByTheRTSafeShim() {
        XCTAssertFalse(RTGuard.isInRenderContext)
        XCTAssertNil(RTGuard.checkRTSafe(JogTransport.guardMessage),
                     "outside a render the jog path is safe")
        let violation = RTGuard.withRenderContext {
            RTGuard.checkRTSafe(JogTransport.guardMessage)
        }
        XCTAssertEqual(violation, JogTransport.guardMessage,
                       "AT-TWIN-4: if a jog callback ever ran on the render thread "
                       + "the §46.3 shim flags it — the offline harness wraps every "
                       + "render in withRenderContext")
        XCTAssertFalse(RTGuard.isInRenderContext, "the flag is restored after the context")
    }

    // MARK: - FR-ENG-11: the jog reaches the engine only via transport intents

    func testHoldPausesThenReleaseResumesAPlayingDeck() {
        let fake = JogFakeEngine()
        fake.current = deckTelemetry(playing: true, playhead: 1000)
        let transport = JogTransport(engine: fake, deck: .a)

        transport.route(.hold)
        XCTAssertEqual(fake.paused, [.a], "touch = hold pauses the playing deck")
        XCTAssertTrue(fake.played.isEmpty)

        transport.route(.release)
        XCTAssertEqual(fake.played, [.a], "lifting resumes a deck that was playing when held")
    }

    func testReleaseDoesNotStartAPausedDeck() {
        let fake = JogFakeEngine()
        fake.current = deckTelemetry(playing: false, playhead: 1000)
        let transport = JogTransport(engine: fake, deck: .a)

        transport.route(.hold)
        XCTAssertTrue(fake.paused.isEmpty, "a paused deck is not re-paused")
        transport.route(.release)
        XCTAssertTrue(fake.played.isEmpty, "lifting a platter must never start a paused deck")
    }

    func testScrubSeeksRelativeToThePlayhead() {
        let fake = JogFakeEngine()
        fake.current = deckTelemetry(playing: true, playhead: 10_000, bpm: 120)
        let transport = JogTransport(engine: fake, deck: .a)

        transport.route(.scrub(radians: .pi / 2))
        let perRadian = Double(JogTransport.scrubSamplesPerRadian(bpm: 120, sampleRate: 48_000))
        let expected = 10_000 + Int64(perRadian * .pi / 2)
        XCTAssertEqual(fake.seeks.count, 1)
        XCTAssertEqual(fake.seeks[0].deck, .a)
        XCTAssertEqual(fake.seeks[0].sample, expected,
                       "a positive platter turn scrubs forward one beat per revolution")
        XCTAssertEqual(fake.seeks[0].quantized, false, "the jog is relative, never quantized")

        transport.route(.scrub(radians: -.pi))
        XCTAssertEqual(fake.seeks.count, 2)
        XCTAssertEqual(fake.seeks[1].sample, 0,
                       "scrubbing before the track start clamps to the beginning")
        XCTAssertEqual(fake.seeks[1].quantized, false)
    }

    func testNudgeBendsOffTheBaseRateAndReleaseRestoresIt() {
        let fake = JogFakeEngine()
        fake.rates = [.a: 1.0]
        let transport = JogTransport(engine: fake, deck: .a)

        transport.route(.nudge(rate: 0.08))
        XCTAssertEqual(fake.rateCommands.last?.rate ?? -1, 1.08, accuracy: 1e-6,
                       "a +8% ring bend is the base rate × 1.08")
        transport.route(.nudge(rate: -0.04))
        XCTAssertEqual(fake.rateCommands.last?.rate ?? -1, 0.96, accuracy: 1e-6)

        transport.route(.release)
        XCTAssertEqual(fake.rateCommands.last?.rate ?? -1, 1.0, accuracy: 1e-6,
                       "release restores the pre-bend base rate")
        XCTAssertEqual(fake.rateCommands.count, 3)
    }

    func testNudgeBendsOffANonUnityBaseRate() {
        let fake = JogFakeEngine()
        fake.rates = [.a: 1.25]
        let transport = JogTransport(engine: fake, deck: .a)

        transport.route(.nudge(rate: 0.08))
        XCTAssertEqual(fake.rateCommands.last?.rate ?? -1, 1.25 * 1.08, accuracy: 1e-6)
        transport.route(.release)
        XCTAssertEqual(fake.rateCommands.last?.rate ?? -1, 1.25, accuracy: 1e-6)
    }

    // MARK: - Detent decision (§40.7.4)

    func testDetentFiresOneBeatPerBoundaryAndHeavyOnDownbeatWrap() {
        // 48 kHz at 120 BPM → one beat every 24 000 samples.
        var boundary: Int64?
        let first = JogDetentDriver.decide(sample: 10_000, masterBPM: 120, downbeatPhase: 0.5,
                                           sampleRate: 48_000, lastBeatBoundary: nil,
                                           lastDownbeatPhase: -1)
        XCTAssertFalse(first.lightBeat)
        XCTAssertFalse(first.heavyDownbeat)
        XCTAssertEqual(first.lastBeatBoundary, 0, "the first armed frame seeds the beat boundary")

        boundary = first.lastBeatBoundary
        let second = JogDetentDriver.decide(sample: 30_000, masterBPM: 120, downbeatPhase: 0.6,
                                            sampleRate: 48_000, lastBeatBoundary: boundary,
                                            lastDownbeatPhase: 0.5)
        XCTAssertTrue(second.lightBeat, "30 000 − 0 ≥ 24 000: one beat crossed")
        XCTAssertFalse(second.heavyDownbeat, "the phase rose — no downbeat wrap")

        boundary = second.lastBeatBoundary
        let third = JogDetentDriver.decide(sample: 45_000, masterBPM: 120, downbeatPhase: 0.9,
                                           sampleRate: 48_000, lastBeatBoundary: boundary,
                                           lastDownbeatPhase: 0.6)
        XCTAssertFalse(third.lightBeat, "45 000 − 24 000 < 24 000: no beat crossed")
        XCTAssertEqual(third.lastBeatBoundary, 24_000, "the boundary holds until crossed")

        boundary = third.lastBeatBoundary
        let fourth = JogDetentDriver.decide(sample: 50_000, masterBPM: 120, downbeatPhase: 0.1,
                                            sampleRate: 48_000, lastBeatBoundary: boundary,
                                            lastDownbeatPhase: 0.9)
        XCTAssertTrue(fourth.lightBeat)
        XCTAssertTrue(fourth.heavyDownbeat, "the downbeat phase wrapped → the heavier accent")
        XCTAssertEqual(fourth.lastBeatBoundary, 48_000)
    }

    func testDetentWithNoTempoProducesNothing() {
        let result = JogDetentDriver.decide(sample: 1000, masterBPM: 0, downbeatPhase: 0.5,
                                            sampleRate: 48_000, lastBeatBoundary: nil,
                                            lastDownbeatPhase: -1)
        XCTAssertFalse(result.lightBeat)
        XCTAssertFalse(result.heavyDownbeat)
        XCTAssertNil(result.lastBeatBoundary)
    }

    // MARK: - Helpers

    private func deckTelemetry(playing: Bool, playhead: Int64, bpm: Double = 120)
        -> EngineTelemetry {
        EngineTelemetry(
            masterSample: playhead,
            masterBPM: bpm,
            downbeatPhase: 0.5,
            deckA: EngineTelemetry.Deck(playheadSample: playhead, bpmEffective: bpm,
                                        phase: 0.25, level: 0.4, playing: playing, synced: false),
            deckB: EngineTelemetry.Deck(),
            renderLoad: 0.1)
    }
}

/// A recording `WorkspaceEngine` fake for the jog's transport seam (FR-ENG-11).
/// Same pattern as `WorkspaceModelTests.FakeWorkspaceEngine`, kept local so the
/// jog tests read the jog's own recording surface.
@MainActor
private final class JogFakeEngine: WorkspaceEngine {
    private let stream = EngineTelemetryStream()
    var telemetry: AsyncStream<EngineTelemetry> { stream.stream }
    var current = EngineTelemetry()
    var masterSample: Int64 { current.masterSample }
    var bufferPeriodMillis: Double = 85.3
    var limiterCeiling: Float?
    var sampleRate: Double = 48_000
    var rates: [PerformanceEngine.Deck: Double] = [.a: 1.0, .b: 1.0]

    private(set) var played: [PerformanceEngine.Deck] = []
    private(set) var paused: [PerformanceEngine.Deck] = []
    private(set) var seeks: [(deck: PerformanceEngine.Deck, sample: Int64, quantized: Bool)] = []
    private(set) var rateCommands: [(deck: PerformanceEngine.Deck, rate: Double)] = []

    func start() throws {}
    func stop() {}
    func load(_ deck: PerformanceEngine.Deck, source: DeckSource) {}
    func play(_ deck: PerformanceEngine.Deck) { played.append(deck) }
    func pause(_ deck: PerformanceEngine.Deck) { paused.append(deck) }
    func cue(_ deck: PerformanceEngine.Deck) {}
    func releaseCue(_ deck: PerformanceEngine.Deck) {}
    func seek(_ deck: PerformanceEngine.Deck, toSample: Int64, quantized: Bool) {
        seeks.append((deck, toSample, quantized))
    }
    func setCue(_ deck: PerformanceEngine.Deck, atSample: Int64) {}
    func triggerHotCue(_ deck: PerformanceEngine.Deck, atSample: Int64) {}
    func setLoopRange(_ deck: PerformanceEngine.Deck, start: Int64, end: Int64) {}
    func setLoop(_ deck: PerformanceEngine.Deck, beats: Double) {}
    func exitLoop(_ deck: PerformanceEngine.Deck) {}
    func setQuantize(_ on: Bool, resolution: QuantizeResolution) {}
    func setRate(_ deck: PerformanceEngine.Deck, rate: Float) { rateCommands.append((deck, Double(rate))) }
    func setKeyLock(_ deck: PerformanceEngine.Deck, locked: Bool) {}
    func setKeyShift(_ deck: PerformanceEngine.Deck, semitones: Float) {}
    func sync(_ deck: PerformanceEngine.Deck, to master: PerformanceEngine.Deck, barSync: Bool) {}
    func unsync(_ deck: PerformanceEngine.Deck) {}
    func isSynced(_ deck: PerformanceEngine.Deck) -> Bool { false }
    func setEQKnobs(_ deck: PerformanceEngine.Deck, low: Float, mid: Float, high: Float) {}
    func setFilter(_ deck: PerformanceEngine.Deck, knob: Float) {}
    func setChannelFader(_ deck: PerformanceEngine.Deck, gain: Float) {}
    func setCrossfader(_ position: Float, curve: CrossfaderCurve) {}
    func setEchoEnabled(_ deck: PerformanceEngine.Deck, enabled: Bool) {}
    func setEchoBeats(_ deck: PerformanceEngine.Deck, beats: Double) {}
    func setEchoDepth(_ deck: PerformanceEngine.Deck, depth: Float) {}
    func setEchoFeedback(_ deck: PerformanceEngine.Deck, feedback: Float) {}
    func armStemSet(_ deck: PerformanceEngine.Deck, stemSet: StemSet?) {}
    func setStemGain(_ deck: PerformanceEngine.Deck, stem: StemKind, gain: Float) {}
    func setStemMute(_ deck: PerformanceEngine.Deck, stem: StemKind, muted: Bool) {}
    func setStemSolo(_ deck: PerformanceEngine.Deck, stem: StemKind, soloed: Bool) {}
    func startRecording() async throws {}
    func stopRecording() async throws -> RecordingEncoder.RecordingOutput? { nil }
    var isRecording: Bool { false }
    func deckRate(_ deck: PerformanceEngine.Deck) -> Double { rates[deck] ?? 1.0 }
    func sampleTelemetry() -> EngineTelemetry { current }
    func pushTelemetry() { stream.push(current) }
}
