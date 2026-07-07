import XCTest

final class TonearmUITests: XCTestCase {
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

    func testAppLaunches() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should launch successfully")
    }

    func testTabBarVisible() throws {
        let listenButton = app.buttons["Listen"]
        let exists = listenButton.waitForExistence(timeout: 15)
        XCTAssertTrue(exists, "Listen tab button should be visible")
        XCTAssertTrue(app.buttons["Playlists"].exists)
        XCTAssertTrue(app.buttons["Library"].exists)
        XCTAssertTrue(app.buttons["Sources"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    func testTabSwitching() throws {
        guard app.buttons["Library"].waitForExistence(timeout: 15) else {
            return XCTFail("Library tab not found")
        }
        app.buttons["Library"].tap()
        sleep(1)

        app.buttons["Sources"].tap()
        sleep(1)

        app.buttons["Listen"].tap()
        sleep(1)
    }
}
