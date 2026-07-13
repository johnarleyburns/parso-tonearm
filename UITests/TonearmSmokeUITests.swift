import XCTest

/// Launch-crash smoke regression: proves the app opens without trapping during
/// `LibraryStore.shared` init (see the v7 syncID backfill fix). Deeper
/// navigation stays covered by `TonearmUITests`.
final class TonearmSmokeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testAppLaunchesWithoutCrashing() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should reach the foreground without crashing")

        let listenButton = app.buttons["Listen"]
        XCTAssertTrue(listenButton.waitForExistence(timeout: 10),
                      "Listen tab button should be visible after a clean launch")
    }
}
