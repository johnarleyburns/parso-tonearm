import XCTest

/// Smoke coverage for the manual DJ console shell and its real load/play/volume/PFL plumbing.
/// Like every other UI test in this repo (CLAUDE.md), this is hand-run before a release, not
/// CI-enforced — the narrowest reliable verification available for a screen `swift test` never
/// compiles (Sources/Features is excluded from the SwiftPM target).
///
/// Orientation is never locked by the app anymore (DJConsoleView.swift) — the simulator starts
/// each test in portrait, so every test that needs the real mixer rotates explicitly first.
final class DJConsoleSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "-uiRegression", "-resetLibrary"]
        app.launch()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testDJTabInPortraitShowsRotatePromptAndCloseReturnsToTheTabBar() throws {
        launch()
        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 10))
        listenTab.tap()

        app.tabBars.buttons["DJ"].tap()

        let prompt = app.otherElements["dj.rotatePrompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10),
                      "Opening the DJ tab in portrait should ask for landscape, not show the mixer")
        XCTAssertFalse(app.otherElements["dj.console"].exists, "The real mixer must not render in portrait")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The tab bar should be hidden behind the full-screen cover")

        app.buttons["dj.rotatePrompt.close"].tap()
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5),
                      "Closing from the rotate prompt should return to the tab that was active before")
        XCTAssertTrue(app.tabBars.firstMatch.isHittable, "The tab bar should be visible again")
    }

    func testDJTabInLandscapeShowsTheMixerWithNoCloseButton() throws {
        launch()
        app.tabBars.buttons["DJ"].tap()
        XCTAssertTrue(app.otherElements["dj.rotatePrompt"].waitForExistence(timeout: 10))

        XCUIDevice.shared.orientation = .landscapeLeft
        let console = app.otherElements["dj.console"]
        XCTAssertTrue(console.waitForExistence(timeout: 10), "Rotating to landscape should present the real mixer")
        XCTAssertFalse(app.otherElements["dj.rotatePrompt"].exists)
        // Immersive: no close chrome at all while actually in landscape (a real report).
        XCTAssertFalse(app.buttons["dj.close"].exists)

        XCTAssertTrue(app.otherElements["dj.deck.left"].exists)
        XCTAssertTrue(app.otherElements["dj.deck.right"].exists)
        XCTAssertTrue(app.otherElements["dj.mixer"].exists)
        XCTAssertTrue(app.buttons["dj.deck.left.play"].exists)
        XCTAssertTrue(app.buttons["dj.deck.right.play"].exists)
    }

    func testTappingTheTrackCardOpensTheLoadSheetAndPickingATrackStartsLoading() throws {
        launch()
        app.tabBars.buttons["DJ"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.otherElements["dj.console"].waitForExistence(timeout: 10))

        // LOAD is not its own button (a real report) — the whole track card is the tap target,
        // same as the platter's own "tap center to load".
        app.otherElements["dj.deck.left"].tap()
        let firstRow = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'dj.load.row.'")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "The load sheet should list the library's tracks")
        firstRow.tap()

        // Loading is real (download/decode/analyze), so just confirm the deck leaves its empty
        // state rather than waiting for a specific step — step text is asserted by hand per
        // CLAUDE.md's UI-regression policy, not here.
        let deck = app.otherElements["dj.deck.left"]
        let stillEmpty = NSPredicate(format: "label CONTAINS 'No track loaded'")
        let left = expectation(for: NSPredicate(format: "NOT (%@)", stillEmpty), evaluatedWith: deck)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 5), .completed,
                       "Picking a track should move the deck out of its empty state")
    }

    func testRecordButtonTogglesToRedDotAndBackWithoutSaving() throws {
        launch()
        app.tabBars.buttons["DJ"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.otherElements["dj.console"].waitForExistence(timeout: 10))

        let rec = app.buttons["dj.mixer.rec"]
        XCTAssertTrue(rec.waitForExistence(timeout: 5))
        XCTAssertEqual(rec.label, "Start recording")
        rec.tap()
        XCTAssertEqual(rec.label, "Stop recording", "Tapping REC should flip it into the recording state")

        // No track was loaded onto either deck, so stopping should hit the "nothing recorded"
        // path rather than opening the save-mix naming alert — asserted by hand per CLAUDE.md's
        // UI-regression policy for anything beyond this basic state-flip round trip.
        rec.tap()
        XCTAssertEqual(rec.label, "Start recording")
    }

    func testClosingAndReopeningKeepsTheSameState() throws {
        launch()
        app.tabBars.buttons["DJ"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.otherElements["dj.console"].waitForExistence(timeout: 10))

        // A real report: closing and reopening the DJ tab used to reset everything. PFL'ing
        // channel A enables Split L/Split R (disabled otherwise) — a simple, reliably-queryable
        // (`isEnabled`, not just a visual color change) example of state that must survive it.
        let pfl = app.buttons["dj.mixer.channelA.pfl"]
        let splitL = app.buttons["dj.mixer.outputRoute.SplitL"]
        XCTAssertTrue(pfl.waitForExistence(timeout: 5))
        XCTAssertFalse(splitL.isEnabled, "Split L starts disabled with no PFL engaged")
        pfl.tap()
        XCTAssertTrue(splitL.isEnabled, "PFL'ing channel A should enable Split L")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.otherElements["dj.rotatePrompt"].waitForExistence(timeout: 10))
        app.buttons["dj.rotatePrompt.close"].tap()
        XCTAssertTrue(app.tabBars.buttons["DJ"].waitForExistence(timeout: 5))

        app.tabBars.buttons["DJ"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.otherElements["dj.console"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["dj.mixer.outputRoute.SplitL"].isEnabled,
                      "PFL must still be engaged after closing and reopening the console")
    }
}
