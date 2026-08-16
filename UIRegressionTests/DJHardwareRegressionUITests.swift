import XCTest

/// The M6 feature lanes — `LANES=djhw` (plan 6.7, spec §53.7–53.12).
///
/// M6 added four things to the shipped app: engine liveness (6.1), the purchase
/// path's honesty (6.2), headphone cue (6.4) and MIDI (6.5). Each is verified
/// in `swift test` at the level where it can be *proved* — the cue's pre-fader
/// tap against rendered audio, the liveness state machine against a driven
/// clock, MIDI translation against values. What those tests cannot see is the
/// same thing layer 3 always exists for: **whether any of it is reachable and
/// wired in the shipped binary** (§49.3a).
///
/// So these lanes are deliberately narrow. They drive the real UI and assert
/// that the controls exist, respond, and change the state the app displays.
/// They do **not** re-assert the DSP — the cue's acoustics are layer 1's job
/// against a deterministic render, and duplicating that here would be slower,
/// flakier and no more true (§12 of the plan).
///
/// Skip-versus-fail (§53.4) is load-bearing here: a MIDI controller cannot be
/// attached to a simulator, so the parts that need one skip with the remedy
/// stated rather than pretending.
@MainActor
final class DJHardwareRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try DJRegression.requireMockCatalogue()
    }

    // MARK: - AT-HW-1 · the cue controls are real and reachable

    /// FR-HW-3: pre-listen has to be reachable from the performance surface
    /// without a drawer (§42.7c's transferable core), and toggling it must
    /// change the control's published state — a CUE button that lights but
    /// tells the engine nothing is exactly the D-10 false green.
    func testAT_HW_01_CueIsReachableAndTogglesOnThePerformanceSurface() throws {
        app = .launchForDJRegression(resetLibrary: true)
        app.openDJDecks()

        let cue = app.waitFor("dj.cue.a", 30)
        XCTAssertTrue(cue.isHittable,
                      "headphone cue must be reachable without opening a drawer (§42.7c)")
        XCTAssertEqual(cue.value as? String, "off")

        cue.tap()
        XCTAssertEqual(app.waitForValue("dj.cue.a", "on"), "on",
                       "tapping CUE arms the deck's pre-listen")

        // Arming with no mode chosen must select a usable one, or the button
        // lights and nothing is audible (plan 6.4).
        let mode = app.element("dj.cue.mode")
        if mode.exists {
            XCTAssertNotEqual(mode.value as? String, "Off",
                              "arming cue selects a mode that can actually be delivered")
        }

        cue.tap()
        XCTAssertEqual(app.waitForValue("dj.cue.a", "off"), "off")
    }

    /// §44.2a: the mode's cost is stated where it is chosen. Split output makes
    /// the master mono, and a user who is about to play out needs to know.
    func testAT_HW_02_TheCueModeStatesItsCost() throws {
        app = .launchForDJRegression(resetLibrary: false)
        app.openDJDecks()
        app.waitFor("dj.cue.a", 30).tap()

        let note = app.element("dj.cue.mode.note")
        guard note.waitForExistence(timeout: 10) else {
            throw XCTSkip("the cue mode note is only on the tablet mixer column; "
                          + "this device shows the compact surface")
        }
        XCTAssertTrue(note.label.localizedCaseInsensitiveContains("mono"),
                      "split output must say the master goes mono, in as many words — "
                      + "the note reads '\(note.label)'")
    }

    // MARK: - AT-HW-3 · MIDI is reachable and honest with no controller

    /// FR-HW-1/2: the mapping screen is on the route table (§49.3a), and with
    /// no controller attached it says so plainly instead of showing an empty
    /// list that reads as a bug.
    func testAT_HW_03_MidiScreenIsReachableAndHonestWithoutHardware() throws {
        app = .launchForDJRegression(resetLibrary: false)
        app.buttons["DJ"].firstMatch.tap()
        app.waitFor("dj.midi", 30).tap()

        // A simulator has no MIDI hardware, so this is the expected state and
        // the lane asserts the *honesty*, not the absence.
        let empty = app.element("midi.devices.empty")
        let anyDevice = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'midi.device.'")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 15) || anyDevice.exists,
                      "with no controller the screen must explain that, not show a blank list")

        // The mapping table is present and offers learning for a real control.
        XCTAssertTrue(app.waitFor("midi.learn.xfader", 15).exists,
                      "the crossfader must be bindable — it is the one control every "
                      + "controller has")
    }

    /// The learn flow's two-step shape is the design (plan 6.5): prompt, then a
    /// commit that stays disabled until a control has actually been captured.
    /// Without hardware nothing can be captured, which is precisely what makes
    /// the disabled state assertable.
    func testAT_HW_04_LearnPromptsAndRefusesToBindNothing() throws {
        app = .launchForDJRegression(resetLibrary: false)
        app.buttons["DJ"].firstMatch.tap()
        app.waitFor("dj.midi", 30).tap()
        app.waitFor("midi.learn.xfader", 15).tap()

        XCTAssertTrue(app.waitFor("midi.learn.prompt", 10).exists,
                      "learning asks the user to move a control")
        let commit = app.waitFor("midi.learn.commit", 10)
        XCTAssertFalse(commit.isEnabled,
                       "nothing was captured, so there is nothing to bind — the button "
                       + "must not be live")
        app.waitFor("midi.learn.cancel", 10).tap()
    }

    // MARK: - AT-HW-6 · a stored profile drives the performance surface

    /// The dj-midi-alpha M1 assertion — the one the whole feature used to fail:
    /// a mapped CC injected through `HardwareService.receive` moves the
    /// crossfader on the live performance surface. The app seeds an active
    /// profile (`-midiSeedProfile`) and the injection hook fires the CC
    /// (`-midiInjectCC`) once the workspace attaches; the lane's only job is to
    /// watch the crossfader's published value leave 0.000. A controller that is
    /// connected but does nothing during a set is the defect this lane exists
    /// to catch, and it is invisible to every layer below.
    func testAT_HW_06_AStoredProfileMovesTheCrossfader() throws {
        app = .launchForDJRegression(resetLibrary: true,
                                     extraArguments: ["-midiSeedProfile", "-midiInjectCC"])
        app.openDJDecks()

        // The injected CC (CC 7, full travel) lands a bipolar crossfader at
        // 1.000. Wait for the value to leave its 0.000 default — the wiring
        // assertion is "the number changed", not a specific gesture.
        let deadline = Date().addingTimeInterval(60)
        var lastSeen: Float?
        while Date() < deadline {
            if let value = app.controlValue(DJRegression.ID.crossfader) {
                lastSeen = value
                if abs(value - 1.0) < 0.01 { break }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let value = lastSeen else {
            XCTFail("the crossfader exposes no published value on this surface — a mapped "
                    + "controller can never be verified here")
            return
        }
        XCTAssertGreaterThan(value, 0.5,
                             "a CC bound to the crossfader never moved it — it reads \(value). "
                             + "The stored profile is not reaching the engine (plan M1's two "
                             + "wires: DJHomeView's store-less MIDI model, and attachMidi's "
                             + "zero call sites).")
    }

    // MARK: - AT-HW-5 · the purchase path

    /// FR-STORE-3 and plan 6.2: the app states what it believes about the
    /// purchase, because with no analytics (NFR-PRIV-2) that row is the only
    /// diagnostic a tester has.
    func testAT_HW_05_PurchaseStateIsVisible() throws {
        app = .launchForDJRegression(resetLibrary: false)
        app.buttons["DJ"].firstMatch.tap()

        let status = app.waitFor("dj.purchase.status", 30)
        XCTAssertFalse(status.label.isEmpty,
                       "the purchase row must state the grant and its source")
        // The regression build grants Pro through the entitlement store
        // (UI_TESTING_ENABLE_PRO), so this run should read as unlocked — the
        // check that the *grant path* the app actually gates on is the one
        // being seeded (the defect §14 recorded).
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("unlocked"),
                      "the automation grant must flow through the store the Pro "
                      + "capability reads — it reads '\(status.label)'")
    }
}

extension XCUIApplication {
    /// Wait for an element's published value to become `expected`, returning
    /// whatever it ended up as so a failure message can show the difference.
    func waitForValue(_ identifier: String, _ expected: String,
                      timeout: TimeInterval = 10) -> String? {
        let element = self.element(identifier)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = element.value as? String, value == expected { return value }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return element.value as? String
    }
}
