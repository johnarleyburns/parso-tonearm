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
        XCTAssertTrue(app.buttons["Mood"].waitForExistence(timeout: 5),
                      "Mood should be a first-class root tab")
        XCTAssertTrue(app.buttons["Find"].waitForExistence(timeout: 5),
                      "Find should be a first-class root tab")
        XCTAssertTrue(element("listen.settings").waitForExistence(timeout: 5),
                      "Settings should be available from Listen's upper-right action")

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

    }

    /// Build a Mix end to end on a fresh install: the Mood Starter library merges, Generate opens
    /// Mix for You with an enabled Play Mix, and playing it closes the sheet and starts the mix.
    func testBuildAMixAndPlayIt() throws {
        launch()
        openTab("Listen", anchor: "Listen")
        let card = app.buttons["listen.buildMix"]
        for _ in 0..<6 where !card.exists { app.swipeUp() }
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Build a Mix card should be on Listen")

        // The first launch merges the Mood Starter library in the background; retry until the
        // builder has mixable tracks.
        let play = app.buttons["mix.preview.play"].firstMatch
        let deadline = Date().addingTimeInterval(90)
        while !play.exists, Date() < deadline {
            card.tap()
            let generate = app.buttons["Generate"].firstMatch
            XCTAssertTrue(generate.waitForExistence(timeout: 10))
            if generate.isEnabled { generate.tap() }
            for _ in 0..<60 where !play.exists { Thread.sleep(forTimeInterval: 0.5) }
            if !play.exists {
                app.buttons["Cancel"].firstMatch.tap()
                Thread.sleep(forTimeInterval: 3)
            }
        }
        XCTAssertTrue(play.exists, "Generate should open Mix for You")
        XCTAssertTrue(play.isEnabled, "Play Mix must be enabled for a generated mix")
        play.tap()

        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed,
                       "Playing a mix should close Build a Mix")
        let miniTitle = app.descendants(matching: .any)["mini.title"].firstMatch
        XCTAssertTrue(miniTitle.waitForExistence(timeout: 15), "The mix should be in the player")
        XCTAssertFalse(miniTitle.label.isEmpty)
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
