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

        // Playlists is a scope within My Music now, not its own root tab
        // (docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md §4).
        app.buttons["My Music"].tap()
        XCTAssertTrue(element("mymusic.scope").waitForExistence(timeout: 10),
                      "My Music tab should show the unified scope bar")
        app.buttons["mymusic.scope.playlists"].tap()
        XCTAssertTrue(app.staticTexts["Playlists"].waitForExistence(timeout: 10),
                      "Selecting the Playlists scope chip should render Playlists")

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

        // The DJ tab now opens Transition Lab directly — no home/menu screen,
        // no mixer (docs/plans/unified-my-music-transition-lab-status.md).
        app.buttons["DJ"].firstMatch.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should still be in the foreground after opening the DJ tab")
        XCTAssertTrue(element("dj.transitionLab").waitForExistence(timeout: 10),
                      "DJ tab should open Transition Lab directly.\n\(app.debugDescription)")
        XCTAssertTrue(element("dj.transition.outgoing").waitForExistence(timeout: 10),
                      "Transition Lab should show the outgoing-track slot.\n\(app.debugDescription)")
        XCTAssertTrue(element("dj.transition.incoming").waitForExistence(timeout: 10),
                      "Transition Lab should show the incoming-track slot.\n\(app.debugDescription)")
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
