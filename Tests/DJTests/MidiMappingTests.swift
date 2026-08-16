import GRDB
import XCTest
@testable import TonearmDJ

/// §44.4 / FR-HW-1/2 — MIDI mapping, translation, persistence and interchange.
///
/// None of this needs a controller, which is the point of the split: CoreMIDI
/// delivery is a thin adapter, and everything that can be *wrong* — value
/// ranges, relative encoders, releases, unknown targets, round-tripping — is a
/// pure function tested here.
@MainActor
final class MidiMappingTests: XCTestCase {

    private let fader = MidiAddress(type: .cc, channel: 1, number: 7)
    private let pad = MidiAddress(type: .note, channel: 1, number: 36)

    // MARK: - Transforms

    func testAbsoluteMapsAcrossTheEngineRange() {
        let unipolar = ValueTransform.unipolar
        XCTAssertEqual(unipolar.apply(MidiMessage(address: fader, value: 0), current: 0), 0)
        XCTAssertEqual(unipolar.apply(MidiMessage(address: fader, value: 127), current: 0), 1)

        // An EQ knob is bipolar: 64 is (near) centre, which is what "unity" is
        // on a physical mixer's detent.
        let bipolar = ValueTransform.bipolar
        XCTAssertEqual(bipolar.apply(MidiMessage(address: fader, value: 0), current: 0), -1)
        XCTAssertEqual(bipolar.apply(MidiMessage(address: fader, value: 127), current: 0), 1)
        XCTAssertEqual(bipolar.apply(MidiMessage(address: fader, value: 64), current: 0),
                       0.0079, accuracy: 0.01)
    }

    func testInvertFlipsAControlThatIsWiredUpsideDown() {
        let inverted = ValueTransform(mode: .absolute, minimum: 0, maximum: 1, invert: true)
        XCTAssertEqual(inverted.apply(MidiMessage(address: fader, value: 0), current: 0), 1)
        XCTAssertEqual(inverted.apply(MidiMessage(address: fader, value: 127), current: 0), 0)
    }

    /// An endless encoder describes a *change*, so the same message must move
    /// the value by the same amount wherever it currently sits — and must not
    /// run off the end of the range.
    func testRelativeEncoderAddsAndClamps() {
        let relative = ValueTransform(mode: .relative, minimum: 0, maximum: 1)
        let up = MidiMessage(address: fader, value: 65)     // +1 tick
        let down = MidiMessage(address: fader, value: 63)   // −1 tick

        let from0 = relative.apply(up, current: 0.5)
        XCTAssertGreaterThan(from0, 0.5)
        XCTAssertEqual(relative.apply(down, current: 0.5), 1 - from0, accuracy: 1e-6,
                       "a tick down is the mirror of a tick up")

        XCTAssertEqual(relative.apply(up, current: 1.0), 1.0, "clamped at the top")
        XCTAssertEqual(relative.apply(down, current: 0.0), 0.0, "clamped at the bottom")
    }

    // MARK: - Routing

    func testAnUnmappedControlDoesNothingAtAll() {
        let profile = ControllerProfile(name: "Test")
        var takeover = TakeoverState()
        XCTAssertNil(MidiRouter.intent(for: MidiMessage(address: fader, value: 100),
                                       profile: profile, takeover: &takeover),
                     "a controller sends LED echoes and touch events — an unmapped "
                     + "address must be silent, not guessed at")
    }

    func testAMappedFaderProducesAContinuousIntent() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.crossfader, at: fader, transform: .bipolar, takeover: .jump)
        var takeover = TakeoverState()

        let intent = MidiRouter.intent(for: MidiMessage(address: fader, value: 127),
                                       profile: profile, takeover: &takeover)
        XCTAssertEqual(intent, .setContinuous(.crossfader, 1))
    }

    /// A pad sends note-on then note-off. Firing on both would trigger
    /// everything twice per tap.
    func testAPadFiresOnPressAndNotOnRelease() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.play(deck: .a), at: pad, transform: ValueTransform(mode: .trigger))
        var takeover = TakeoverState()

        XCTAssertEqual(MidiRouter.intent(for: MidiMessage(address: pad, value: 127),
                                         profile: profile, takeover: &takeover),
                       .press(.play(deck: .a)))
        XCTAssertEqual(MidiRouter.intent(for: MidiMessage(address: pad, value: 0),
                                         profile: profile, takeover: &takeover),
                       .ignoredRelease(.play(deck: .a)),
                       "recognised, and deliberately does nothing")
    }

    // MARK: - Learning

    /// One control does one thing, and one action has one control. A
    /// half-relearned map that moves the crossfader from two knobs is worse
    /// than an unmapped controller.
    func testLearningReplacesBothTheAddressAndTheAction() {
        var profile = ControllerProfile(name: "Test")
        let otherKnob = MidiAddress(type: .cc, channel: 1, number: 8)

        profile.learn(.crossfader, at: fader, transform: .bipolar)
        profile.learn(.channelFader(deck: .a), at: fader, transform: .unipolar)
        XCTAssertEqual(profile.bindings.count, 1, "re-using an address replaces its binding")
        XCTAssertEqual(profile.bindings.first?.action, .channelFader(deck: .a))

        profile.learn(.channelFader(deck: .a), at: otherKnob, transform: .unipolar)
        XCTAssertEqual(profile.bindings.count, 1, "re-binding an action moves it, never duplicates")
        XCTAssertEqual(profile.bindings.first?.address, otherKnob)
    }

    func testHotCueIsNotOfferedForBindingWhileItCannotWork() {
        // It stays in the vocabulary (a profile from elsewhere may carry it)
        // but must not be offered, because nothing reads stored cue points yet.
        XCTAssertFalse(EngineAction.bindableActions.contains { action in
            if case .hotCue = action { return true }
            return false
        })
        XCTAssertNotNil(EngineAction.parse(target: "deckA.hotcue.1"))
    }

    // MARK: - Targets and interchange

    func testEveryBindableActionRoundTripsThroughItsPersistedTarget() {
        for action in EngineAction.bindableActions {
            XCTAssertEqual(EngineAction.parse(target: action.target), action,
                           "\(action.target) must survive the database")
        }
    }

    /// A profile from a newer version may name actions this build does not
    /// know. Skipping is the only safe answer — the alternative is binding a
    /// user's crossfader to whatever happened to be first.
    func testAnUnknownTargetIsRejectedRatherThanDefaulted() {
        XCTAssertNil(EngineAction.parse(target: "deckA.timeMachine"))
        XCTAssertNil(EngineAction.parse(target: "deckC.play"))
        XCTAssertNil(EngineAction.parse(target: "nonsense"))
    }

    func testProfileJSONRoundTrips() throws {
        var profile = ControllerProfile(name: "DDJ-FLX4", vendor: "AlphaTheta",
                                        endpointName: "DDJ-FLX4")
        profile.learn(.crossfader, at: fader, transform: .bipolar)
        profile.learn(.play(deck: .b), at: pad, transform: ValueTransform(mode: .trigger))

        let data = try ControllerProfileStore.exportData(profile)
        let restored = try ControllerProfileStore.importProfile(from: data)
        XCTAssertEqual(restored, profile)
    }

    /// A profile exported by the pre-M2 build has no `takeover` key. It must
    /// still import — with the action's default — rather than failing to
    /// decode: a mapping is still a mapping across versions.
    func testAnOldProfileWithoutTakeoverStillImports() throws {
        let oldJSON = """
        {
          "name": "Old Controller",
          "bindings": [
            {
              "address": {"type": "cc", "channel": 1, "number": 7},
              "action": {"play": {"deck": "a"}},
              "transform": {"mode": "trigger", "minimum": 0, "maximum": 1, "invert": false}
            }
          ]
        }
        """.data(using: .utf8)!
        let profile = try ControllerProfileStore.importProfile(from: oldJSON)
        XCTAssertEqual(profile.name, "Old Controller")
        XCTAssertEqual(profile.bindings.count, 1)
        XCTAssertEqual(profile.binding(for: fader)?.action, .play(deck: .a))
        XCTAssertEqual(profile.binding(for: fader)?.takeover, .jump,
                       "a button from an old profile jumps — the action's default")
    }

    // MARK: - Soft takeover (plan dj-midi-alpha M2)

    /// The default is the whole point of M2: continuous absolute controls pick
    /// up (a stale fader must not slam the channel), buttons and relative
    /// encoders jump (a button has no position, an encoder has no position).
    func testTakeoverDefaultsFollowTheAction() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.crossfader, at: fader, transform: .bipolar)
        profile.learn(.channelFader(deck: .a),
                      at: MidiAddress(type: .cc, channel: 1, number: 8), transform: .unipolar)
        profile.learn(.play(deck: .a), at: pad, transform: ValueTransform(mode: .trigger))

        XCTAssertEqual(profile.binding(for: fader)?.takeover, .pickup)
        XCTAssertEqual(profile.binding(for: MidiAddress(type: .cc, channel: 1, number: 8))?.takeover,
                       .pickup)
        XCTAssertEqual(profile.binding(for: pad)?.takeover, .jump,
                       "a button jumps — pickup is meaningless for a press")
    }

    /// A fader at 1.0 over an engine at 0.2 must not move it: the router says
    /// which way to go (`.awaitingPickup`) until the physical value crosses the
    /// engine value, then follows.
    func testPickupAwaitsTheCrossingThenClaimsTheControl() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.channelFader(deck: .a), at: fader, transform: .unipolar)
        var takeover = TakeoverState()

        // Physical at 1.0, engine at 0.2: not there yet — move nothing, say
        // which way (positive distance = physical above the engine value).
        let far = MidiRouter.intent(for: MidiMessage(address: fader, value: 127),
                                    profile: profile, currentValue: 0.2,
                                    takeover: &takeover)
        XCTAssertEqual(far, .awaitingPickup(.channelFader(deck: .a), distance: 0.8))

        // Move the fader down in steps; each stays awaiting until it crosses
        // 0.2, then the control is claimed and follows.
        var intent = MidiRouter.intent(for: MidiMessage(address: fader, value: 80),
                                       profile: profile, currentValue: 0.2,
                                       takeover: &takeover)
        guard case .awaitingPickup = intent else {
            return XCTFail("still above the engine value — must await")
        }
        intent = MidiRouter.intent(for: MidiMessage(address: fader, value: 40),
                                   profile: profile, currentValue: 0.2,
                                   takeover: &takeover)
        guard case .awaitingPickup = intent else {
            return XCTFail("40/127 = 0.31 — still above 0.2")
        }
        // 25/127 ≈ 0.197 — now below 0.2, having crossed since the last
        // message. Claimed.
        intent = MidiRouter.intent(for: MidiMessage(address: fader, value: 25),
                                   profile: profile, currentValue: 0.2,
                                   takeover: &takeover)
        guard case .setContinuous(let action, let value) = intent else {
            return XCTFail("the crossing must claim the control, got \(String(describing: intent))")
        }
        XCTAssertEqual(action, .channelFader(deck: .a))
        XCTAssertEqual(value, 25.0 / 127.0, accuracy: 1e-6)

        // Once picked up, the control follows directly.
        let follow = MidiRouter.intent(for: MidiMessage(address: fader, value: 100),
                                       profile: profile, currentValue: 0.2,
                                       takeover: &takeover)
        XCTAssertEqual(follow, .setContinuous(.channelFader(deck: .a), 100.0 / 127.0))
    }

    /// The crossing is detected in both directions: a fader moving up over the
    /// engine value claims it exactly like one moving down.
    func testPickupCrossingWorksInBothDirections() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.channelFader(deck: .a), at: fader, transform: .unipolar)
        var takeover = TakeoverState()

        // Physical below the engine value (0.0 vs 0.2): await, move up.
        _ = MidiRouter.intent(for: MidiMessage(address: fader, value: 0),
                              profile: profile, currentValue: 0.2, takeover: &takeover)
        _ = MidiRouter.intent(for: MidiMessage(address: fader, value: 10),
                              profile: profile, currentValue: 0.2, takeover: &takeover)
        // 40/127 ≈ 0.31 — crosses 0.2 from below, claims the control.
        let intent = MidiRouter.intent(for: MidiMessage(address: fader, value: 40),
                                       profile: profile, currentValue: 0.2,
                                       takeover: &takeover)
        guard case .setContinuous = intent else {
            return XCTFail("the upward crossing must claim the control, got \(String(describing: intent))")
        }
    }

    /// A control already at the engine value picks up immediately — including
    /// at the ends of travel, where a fader parked at 0 or 1 must be usable.
    func testPickupEngagesImmediatelyWithinToleranceIncludingTheEnds() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.channelFader(deck: .a), at: fader, transform: .unipolar)

        // Physical at 0, engine at 0 — already there.
        var takeover = TakeoverState()
        let parked = MidiRouter.intent(for: MidiMessage(address: fader, value: 0),
                                       profile: profile, currentValue: 0, takeover: &takeover)
        XCTAssertEqual(parked, .setContinuous(.channelFader(deck: .a), 0))

        // Physical at 1, engine at 1 — already there.
        takeover = TakeoverState()
        let top = MidiRouter.intent(for: MidiMessage(address: fader, value: 127),
                                    profile: profile, currentValue: 1, takeover: &takeover)
        XCTAssertEqual(top, .setContinuous(.channelFader(deck: .a), 1))
    }

    /// A relative encoder has no position to pick up: even with a pickup
    /// binding, its increments apply as today.
    func testRelativeEncodersSkipTakeoverEntirely() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.tempo(deck: .a), at: fader,
                      transform: ValueTransform(mode: .relative, minimum: -0.16, maximum: 0.16),
                      takeover: .pickup)
        var takeover = TakeoverState()

        let intent = MidiRouter.intent(for: MidiMessage(address: fader, value: 65),
                                       profile: profile, currentValue: 0.02,
                                       takeover: &takeover)
        guard case .setContinuous(let action, let value) = intent else {
            return XCTFail("an encoder tick must apply as a change, got \(String(describing: intent))")
        }
        XCTAssertEqual(action, .tempo(deck: .a))
        XCTAssertEqual(value, 0.02 + 1.0 / 127.0 * 0.32, accuracy: 1e-3,
                       "the increment applies to the engine value directly")
    }

    /// `.scale` anchors at the engine value and moves proportionally to the
    /// remaining physical travel: a fader at the top over an engine at the
    /// bottom never jumps, it scales down.
    func testScaleMovesProportionalToRemainingTravel() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.channelFader(deck: .a), at: fader, transform: .unipolar,
                      takeover: .scale)
        var takeover = TakeoverState()

        // First message anchors at (1.0, 0.2), moves nothing.
        let anchor = MidiRouter.intent(for: MidiMessage(address: fader, value: 127),
                                       profile: profile, currentValue: 0.2,
                                       takeover: &takeover)
        guard case .awaitingPickup = anchor else {
            return XCTFail("the first scale message must anchor, got \(String(describing: anchor))")
        }

        // Half-way down the physical travel (64/127 ≈ 0.504) moves the engine
        // half of its 0.2 of travel toward 0.
        let half = MidiRouter.intent(for: MidiMessage(address: fader, value: 64),
                                     profile: profile, currentValue: 0.2,
                                     takeover: &takeover)
        guard case .setContinuous(_, let value) = half else {
            return XCTFail("after anchoring, scale follows — got \(String(describing: half))")
        }
        XCTAssertEqual(value, 0.2 - (1.0 - 64.0 / 127.0) * 0.2, accuracy: 1e-4)
    }

    /// Reset — a finger driving the action on the touchscreen — makes the
    /// physical control claim the value again from scratch.
    func testResettingPickupRequiresANewCrossing() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.channelFader(deck: .a), at: fader, transform: .unipolar)
        var takeover = TakeoverState()

        // Pick up at 1.0.
        _ = MidiRouter.intent(for: MidiMessage(address: fader, value: 127),
                              profile: profile, currentValue: 1.0, takeover: &takeover)
        takeover.resetPickup(for: fader)

        // The engine has moved to 0.2 meanwhile (a finger drove it); the
        // physical control must re-pick-up instead of slamming it.
        let intent = MidiRouter.intent(for: MidiMessage(address: fader, value: 127),
                                       profile: profile, currentValue: 0.2,
                                       takeover: &takeover)
        XCTAssertEqual(intent, .awaitingPickup(.channelFader(deck: .a), distance: 0.8))
    }

    // MARK: - Persistence

    private func makePool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MidiMappingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tonearm-dj.sqlite")
        let pool = try DJDatabase.open(at: url)
        return (pool, dir)
    }

    func testAProfileSurvivesTheDatabaseRoundTrip() throws {
        let (pool, _) = try makePool()
        let store = ControllerProfileStore(pool: pool)

        var profile = ControllerProfile(name: "Test Controller", vendor: "Acme",
                                        endpointName: "Acme Controller")
        profile.learn(.crossfader, at: fader, transform: .bipolar)
        profile.learn(.eq(deck: .b, band: .low),
                      at: MidiAddress(type: .cc, channel: 2, number: 12), transform: .bipolar)
        profile.learn(.record, at: pad, transform: ValueTransform(mode: .trigger))

        try store.save(profile, syncID: "sync-1")
        let loaded = try XCTUnwrap(store.activeProfile())

        XCTAssertEqual(loaded.name, "Test Controller")
        XCTAssertEqual(loaded.bindings.count, 3)
        XCTAssertEqual(loaded.binding(for: fader)?.action, .crossfader)
        XCTAssertEqual(loaded.binding(for: pad)?.action, .record)
        XCTAssertEqual(loaded.binding(for: MidiAddress(type: .cc, channel: 2, number: 12))?.action,
                       .eq(deck: .b, band: .low))
    }

    /// Re-saving after a learn must replace the map, not merge into it —
    /// otherwise a control the user re-bound keeps its old binding too.
    func testResavingReplacesTheMapRatherThanMerging() throws {
        let (pool, _) = try makePool()
        let store = ControllerProfileStore(pool: pool)

        var profile = ControllerProfile(name: "Test")
        profile.learn(.crossfader, at: fader, transform: .bipolar)
        try store.save(profile, syncID: "sync-1")

        profile.bindings.removeAll()
        profile.learn(.record, at: pad, transform: ValueTransform(mode: .trigger))
        try store.save(profile, syncID: "sync-1")

        let loaded = try XCTUnwrap(store.activeProfile())
        XCTAssertEqual(loaded.bindings.count, 1)
        XCTAssertNil(loaded.binding(for: fader), "the old binding is gone, not merged")
    }

    /// Plan dj-midi-alpha M1's second wire, asserted at the model: the MIDI
    /// settings screen is built with a store-backed model that loads the
    /// existing active profile at construction — a mapping learned last week is
    /// what the table shows when the user comes back, never an empty one.
    func testTheSettingsModelLoadsTheStoredActiveProfile() throws {
        let (pool, _) = try makePool()
        let store = ControllerProfileStore(pool: pool)

        var profile = ControllerProfile(name: "DDJ-FLX4", vendor: "AlphaTheta",
                                        endpointName: "DDJ-FLX4")
        profile.learn(.crossfader, at: fader, transform: .bipolar)
        try store.save(profile, syncID: "sync-1")

        let model = MidiSettingsModel.live(hardware: HardwareService(), store: store)
        let loaded = model.profile
        XCTAssertEqual(loaded.name, "DDJ-FLX4")
        XCTAssertEqual(loaded.bindings.count, 1)
        XCTAssertEqual(loaded.binding(for: fader)?.action, .crossfader,
                       "the screen shows what the user already taught it")
    }

    /// M2: the takeover mode survives the database like the transform does —
    /// a fader the user relies on to pick up must still pick up next week.
    func testTakeoverSurvivesTheDatabaseRoundTrip() throws {
        let (pool, _) = try makePool()
        let store = ControllerProfileStore(pool: pool)

        var profile = ControllerProfile(name: "Test")
        profile.learn(.crossfader, at: fader, transform: .bipolar, takeover: .scale)
        profile.learn(.channelFader(deck: .a),
                      at: MidiAddress(type: .cc, channel: 1, number: 9),
                      transform: .unipolar, takeover: .pickup)
        profile.learn(.record, at: pad, transform: ValueTransform(mode: .trigger),
                      takeover: .jump)
        try store.save(profile, syncID: "sync-1")

        let loaded = try XCTUnwrap(store.activeProfile())
        XCTAssertEqual(loaded.binding(for: fader)?.takeover, .scale)
        XCTAssertEqual(loaded.binding(for: MidiAddress(type: .cc, channel: 1, number: 9))?.takeover,
                       .pickup)
        XCTAssertEqual(loaded.binding(for: pad)?.takeover, .jump)
    }

    // MARK: - The guided learn walkthrough (plan dj-midi-alpha M4)

    /// Every step the walkthrough offers must be actually bindable — a step
    /// that offers something the learn UI refuses would dead-end the flow.
    func testEverySetupStepIsBindable() {
        let bindable = Set(EngineAction.bindableActions)
        for step in MidiSettingsModel.setupSteps {
            XCTAssertTrue(bindable.contains(step.action),
                          "the walkthrough teaches \(step.action.target), which is not "
                          + "offered by the learn UI")
        }
        // And it is the full essential set in performance order — the first
        // step is the crossfader, the last is record.
        XCTAssertEqual(MidiSettingsModel.setupSteps.first?.action, .crossfader)
        XCTAssertEqual(MidiSettingsModel.setupSteps.last?.action, .record)
    }

    /// Skipping a step leaves the bindings made before it intact, and advances
    /// to the next step — an exitable-at-any-point flow.
    func testSkippingLeavesEarlierBindingsIntact() async throws {
        let (pool, _) = try makePool()
        let store = ControllerProfileStore(pool: pool)
        let model = MidiSettingsModel(hardware: HardwareService(), store: store)
        model.startSetup()
        await settle()

        // Bind the first step (the crossfader).
        model.hardware.receive(MidiMessage(address: fader, value: 127))
        await settle()
        XCTAssertEqual(model.capturedAddress, fader)
        model.commitLearning()

        // Skip the second step.
        let second = model.currentSetupStep
        XCTAssertEqual(second?.action, .channelFader(deck: .a))
        model.skipSetupStep()

        XCTAssertEqual(model.currentSetupStep?.action, .channelFader(deck: .b),
                       "skipping advances to the following step")
        XCTAssertEqual(model.profile.binding(for: fader)?.action, .crossfader,
                       "the mapping made before the skip is intact")
        XCTAssertTrue(model.isRunningSetup, "the walkthrough continues after a skip")
    }

    /// Driving the walkthrough to completion writes one profile with the
    /// expected number of bindings — the profile a fresh user ships with.
    func testCompletingTheWalkthroughWritesOneProfileWithTheExpectedCount() async throws {
        let (pool, _) = try makePool()
        let store = ControllerProfileStore(pool: pool)
        let model = MidiSettingsModel(hardware: HardwareService(), store: store)
        model.startSetup()
        await settle()

        var number = 1
        while let step = model.currentSetupStep {
            let address = MidiAddress(type: .cc, channel: 1, number: number)
            model.hardware.receive(MidiMessage(address: address, value: 64 + number % 3))
            await settle()
            XCTAssertEqual(model.capturedAddress, address,
                           "step \(number) (\(step.action.target)) never captured a control")
            model.commitLearning()
            number += 1
        }

        XCTAssertNil(model.currentSetupStep, "the walkthrough completed")
        XCTAssertEqual(model.profile.bindings.count, MidiSettingsModel.setupSteps.count,
                       "every step bound one control")
        let stored = try XCTUnwrap(store.activeProfile())
        XCTAssertEqual(stored.bindings.count, MidiSettingsModel.setupSteps.count,
                       "and the profile was written through to the database")
    }

    private func settle() async {
        for _ in 0..<6 { await Task.yield() }
    }
}
