import XCTest
import UIKit

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

    func testAddRemoteLibraryUsernamePasswordFieldsAcceptPaste() throws {
        launch(arguments: ["UI_TESTING_ENABLE_PRO"])
        openAddRemoteLibrarySheet()

        paste("https://music.example.com",
              into: app.textFields["Add Remote Library SERVER URL"])
        paste("launch-user",
              into: app.textFields["Add Remote Library USERNAME"])
        paste("launch-password-very-long",
              into: app.secureTextFields["Add Remote Library PASSWORD"])

        let connectSubsonic = app.buttons["Connect Subsonic"]
        XCTAssertTrue(connectSubsonic.waitForExistence(timeout: 5),
                      "Subsonic connect action should exist")
        XCTAssertTrue(connectSubsonic.isEnabled,
                      "Pasted URL, username, and password should enable Subsonic connect")
    }

    func testAddRemoteLibraryTokenFieldAcceptsPaste() throws {
        launch(arguments: ["UI_TESTING_ENABLE_PRO"])
        openAddRemoteLibrarySheet()

        app.buttons["Plex"].tap()
        paste("https://music.example.com",
              into: app.textFields["Add Remote Library SERVER URL"])
        paste("plex-token-very-long",
              into: app.secureTextFields["Add Remote Library PLEX TOKEN"])

        let connectPlex = app.buttons["Connect Plex"]
        XCTAssertTrue(connectPlex.waitForExistence(timeout: 5),
                      "Plex connect action should exist")
        XCTAssertTrue(connectPlex.isEnabled,
                      "Pasted URL and token should enable Plex connect")
    }

    private func launch(arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"] + arguments
        app.launch()
    }

    private func openAddRemoteLibrarySheet(file: StaticString = #filePath,
                                           line: UInt = #line) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should reach the foreground without crashing",
                      file: file,
                      line: line)
        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 15),
                      "Global Add button should be visible",
                      file: file,
                      line: line)
        addButton.tap()

        let addRemote = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Add Remote Library"))
            .firstMatch
        XCTAssertTrue(addRemote.waitForExistence(timeout: 10),
                      "Add menu should expose Add Remote Library",
                      file: file,
                      line: line)
        addRemote.tap()

        XCTAssertTrue(app.staticTexts["Add Remote Library"].waitForExistence(timeout: 10),
                      "Add Remote Library sheet should open for Pro users",
                      file: file,
                      line: line)
    }

    private func paste(_ text: String,
                       into field: XCUIElement,
                       file: StaticString = #filePath,
                       line: UInt = #line) {
        UIPasteboard.general.string = text
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "Field should exist before paste",
                      file: file,
                      line: line)
        field.tap()
        field.press(forDuration: 1.0)

        let pasteItem = app.menuItems["Paste"]
        XCTAssertTrue(pasteItem.waitForExistence(timeout: 3),
                      "Paste menu item should appear",
                      file: file,
                      line: line)
        pasteItem.tap()
    }
}
