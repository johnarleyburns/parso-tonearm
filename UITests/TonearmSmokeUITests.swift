import XCTest

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

    func testAppBootsAndVisitsAllTabs() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should reach the foreground without crashing")

        let tabs: [(button: String, anchor: String)] = [
            ("Listen", "Listen"),
            ("Playlists", "Playlists"),
            ("Library", "Library"),
            ("Sources", "Sources"),
            ("Settings", "Settings"),
        ]

        for tab in tabs {
            let button = app.buttons[tab.button]
            XCTAssertTrue(button.waitForExistence(timeout: 15),
                          "\(tab.button) tab button should be visible")
            button.tap()

            let anchor = app.staticTexts[tab.anchor]
            XCTAssertTrue(anchor.waitForExistence(timeout: 10),
                          "\(tab.anchor) tab should render a stable title")
        }
    }
}
