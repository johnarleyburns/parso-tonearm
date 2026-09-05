import XCTest

final class TonearmSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testIPhoneSmokeOpensPlaylistPlaysAndSkips() throws {
        launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should reach the foreground without crashing")

        openTab("Listen", anchor: "Listen")
        openTab("Playlists", anchor: "Playlists")

        let ambientPlaylist = element("playlist.ambient")
        XCTAssertTrue(ambientPlaylist.waitForExistence(timeout: 10),
                      "Built-in Ambient playlist should be visible")
        ambientPlaylist.tap()

        let rain = element("ambient.track.ambient-rain")
        XCTAssertTrue(rain.waitForExistence(timeout: 10),
                      "Built-in Rainy Day track should be visible")
        rain.tap()

        let miniTitle = app.staticTexts["mini.title"]
        XCTAssertTrue(miniTitle.waitForExistence(timeout: 10),
                      "Mini player title should appear after starting playback")
        XCTAssertEqual(miniTitle.label, "Rainy Day")

        let playPause = app.buttons["mini.playpause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10),
                      "Mini player play/pause control should appear")
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 5),
                      "Starting the built-in track should enter playing state")

        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "paused", timeout: 5),
                      "Play/pause should pause playback")
        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 5),
                      "Play/pause should resume playback")

        let nextButton = app.buttons["mini.next"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5),
                      "Mini player next control should exist")
        nextButton.tap()
        XCTAssertTrue(waitForLabel(miniTitle, equals: "Ocean Waves", timeout: 5),
                      "Skipping forward should advance to the next built-in track")

        // User-reported: tapping the DJ tab, and opening the DJ mixer from
        // it, crashes the app.
        app.buttons["DJ"].firstMatch.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should still be in the foreground after opening the DJ tab")
        let decksEntry = app.buttons["dj.decks"].firstMatch
        XCTAssertTrue(decksEntry.waitForExistence(timeout: 10),
                      "DJ entry screen should render its Decks card after opening the DJ tab.\n\(app.debugDescription)")

        decksEntry.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should still be in the foreground after opening the DJ mixer")
        // `dj.master.bar` only renders once a track is loaded (it reads the
        // beat grid), so it's not a usable anchor for a no-track smoke check.
        // `dj.transport.record` is always present.
        XCTAssertTrue(element("dj.transport.record").waitForExistence(timeout: 10),
                      "DJ mixer workspace should render its transport controls after tapping Open DJ Mixer.\n\(app.debugDescription)")
    }

    private func launch(arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "-uiRegression", "-resetLibrary"] + arguments
        app.launch()
    }

    private func openTab(_ tab: String,
                         anchor: String,
                         file: StaticString = #filePath,
                         line: UInt = #line) {
        let button = app.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 15),
                      "\(tab) tab button should be visible",
                      file: file,
                      line: line)
        button.tap()

        let title = app.staticTexts[anchor]
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "\(anchor) should render after opening \(tab)",
                      file: file,
                      line: line)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitForValue(_ element: XCUIElement,
                              equals expected: String,
                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == expected { return true }
            usleep(200_000)
        }
        return (element.value as? String) == expected
    }

    private func waitForLabel(_ element: XCUIElement,
                              equals expected: String,
                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label == expected { return true }
            usleep(200_000)
        }
        return element.label == expected
    }
}
