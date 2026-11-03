import XCTest

/// Smoke coverage for the manual DJ console shell and its real load/play/volume/PFL plumbing.
/// Like every other UI test in this repo (CLAUDE.md), this is hand-run before a release, not
/// CI-enforced — the narrowest reliable verification available for a screen `swift test` never
/// compiles (Sources/Features is excluded from the SwiftPM target).
final class DJConsoleSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "-uiRegression", "-resetLibrary"]
        app.launch()
    }

    func testDJTabOpensFullScreenConsoleAndCloseReturns() throws {
        launch()
        let listenTab = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listenTab.waitForExistence(timeout: 10))
        listenTab.tap()

        app.tabBars.buttons["DJ"].tap()

        let console = app.otherElements["dj.console"]
        XCTAssertTrue(console.waitForExistence(timeout: 10), "Selecting DJ should present the full-screen console")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The tab bar should be hidden behind the full-screen cover")

        XCTAssertTrue(app.otherElements["dj.deck.left"].exists)
        XCTAssertTrue(app.otherElements["dj.deck.right"].exists)
        XCTAssertTrue(app.otherElements["dj.mixer"].exists)
        XCTAssertTrue(app.buttons["dj.deck.left.load"].exists)
        XCTAssertTrue(app.buttons["dj.deck.right.load"].exists)
        XCTAssertTrue(app.buttons["dj.deck.left.play"].exists)
        XCTAssertTrue(app.buttons["dj.deck.right.play"].exists)

        app.buttons["dj.close"].tap()
        XCTAssertTrue(listenTab.waitForExistence(timeout: 5),
                      "Closing the console should return to the tab that was active before")
        XCTAssertTrue(app.tabBars.firstMatch.isHittable, "The tab bar should be visible again")
    }

    func testLoadSheetOpensAndPickingATrackStartsLoading() throws {
        launch()
        app.tabBars.buttons["DJ"].tap()
        XCTAssertTrue(app.otherElements["dj.console"].waitForExistence(timeout: 10))

        app.buttons["dj.deck.left.load"].tap()
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
}
