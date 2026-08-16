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
        XCTAssertNil(MidiRouter.intent(for: MidiMessage(address: fader, value: 100),
                                       profile: profile),
                     "a controller sends LED echoes and touch events — an unmapped "
                     + "address must be silent, not guessed at")
    }

    func testAMappedFaderProducesAContinuousIntent() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.crossfader, at: fader, transform: .bipolar)

        let intent = MidiRouter.intent(for: MidiMessage(address: fader, value: 127),
                                       profile: profile)
        XCTAssertEqual(intent, .setContinuous(.crossfader, 1))
    }

    /// A pad sends note-on then note-off. Firing on both would trigger
    /// everything twice per tap.
    func testAPadFiresOnPressAndNotOnRelease() {
        var profile = ControllerProfile(name: "Test")
        profile.learn(.play(deck: .a), at: pad, transform: ValueTransform(mode: .trigger))

        XCTAssertEqual(MidiRouter.intent(for: MidiMessage(address: pad, value: 127),
                                         profile: profile),
                       .press(.play(deck: .a)))
        XCTAssertEqual(MidiRouter.intent(for: MidiMessage(address: pad, value: 0),
                                         profile: profile),
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
}
