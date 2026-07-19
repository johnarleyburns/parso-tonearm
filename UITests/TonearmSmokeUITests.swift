import XCTest

final class TonearmSmokeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testAppBootsAndVisitsAllTabs() throws {
        launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should reach the foreground without crashing")

        let tabs: [(button: String, anchor: String)] = [
            ("Listen", "Listen"),
            ("Playlists", "Playlists"),
            ("Music", "Music"),
            ("Libraries", "Libraries"),
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

    func testFreeAddRemoteLibraryEntryShowsPaywall() throws {
        launch(arguments: ["UI_TESTING_RESET_PRO"])

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should reach the foreground without crashing")
        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 15),
                      "Global Add button should be visible")
        addButton.tap()

        let addRemote = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Add Remote Library"))
            .firstMatch
        XCTAssertTrue(addRemote.waitForExistence(timeout: 10),
                      "Add menu should expose Add Remote Library")
        addRemote.tap()

        let paywall = app.staticTexts["Remote Libraries"]
        XCTAssertTrue(paywall.waitForExistence(timeout: 10),
                      "Free Add Remote Library entry should present the Pro paywall")
        XCTAssertTrue(app.buttons["Unlock Remote Libraries"].exists,
                      "Paywall should expose the Remote Libraries purchase action")
    }

    private func launch(arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"] + arguments
        app.launch()
    }
}
