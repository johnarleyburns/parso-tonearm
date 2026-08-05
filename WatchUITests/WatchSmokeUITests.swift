import XCTest

/// The single watchOS simulator smoke test for Platterhead. Verifies the app
/// boots, seeded fixtures render, and — critically — that tapping "Play All"
/// actually starts playback and that play/pause toggles the real transport
/// state. Run locally; CI runs `swift test` only.
final class WatchSmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWatchSmokeBootsPlaysAndBrowses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "SEED_WATCH_FIXTURES", "SEED_MUSOPEN_FIXTURES"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        playPlaylist(app,
                     name: "Built-in Playlist",
                     expectedTrack: nil,
                     playlistTimeout: 10,
                     requireElapsedAdvance: false)

        // Now Playing presents and playback starts from the seeded local WAV.
        // The play/pause button's accessibility value reflects the real
        // transport state, so this confirms audio actually started.
        let playPause = app.buttons["np.playpause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8),
                      "Now Playing / play-pause control never appeared")
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 8),
                      "Tapping Play All did not start playback")

        // Pause, then resume — confirm the transport flips both ways.
        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "paused", timeout: 5),
                      "Play/pause did not pause playback")
        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 5),
                      "Play/pause did not resume playback")

        // Skip forward/back — controls exist whenever Now Playing is showing.
        let nextButton = app.buttons["np.next"]
        XCTAssertTrue(nextButton.exists)
        nextButton.tap()
        let prevButton = app.buttons["np.prev"]
        XCTAssertTrue(prevButton.exists)
        prevButton.tap()

        // Dismiss Now Playing (sheet) and return to the root list.
        closeNowPlaying(app)
        popToRoot(app)

        playPlaylist(app,
                     name: "Musopen Stream Smoke",
                     expectedTrack: "Prelude Op. 28 no. 7",
                     playlistTimeout: 60,
                     requireElapsedAdvance: true)
        closeNowPlaying(app)
        popToRoot(app)

        playPlaylist(app,
                     name: "Musopen Download Smoke",
                     expectedTrack: "Prelude Op. 28 no. 10",
                     playlistTimeout: 90,
                     requireElapsedAdvance: true)
        closeNowPlaying(app)
        popToRoot(app)

        // Storage shows the live iPhone connection status.
        let rootStorage = app.buttons["root.storage"]
        XCTAssertTrue(rootStorage.waitForExistence(timeout: 5))
        rootStorage.tap()
        let phoneStatus = app.staticTexts["storage.phoneStatus"]
        XCTAssertTrue(phoneStatus.waitForExistence(timeout: 5),
                      "Storage screen did not render the iPhone status")
    }

    private func playPlaylist(_ app: XCUIApplication,
                              name: String,
                              expectedTrack: String?,
                              playlistTimeout: TimeInterval,
                              requireElapsedAdvance: Bool) {
        let rootPlaylists = app.buttons["root.playlists"]
        XCTAssertTrue(rootPlaylists.waitForExistence(timeout: 10),
                      "Root did not render the Playlists row")
        rootPlaylists.tap()

        let playlistRow = app.staticTexts[name]
        XCTAssertTrue(playlistRow.waitForExistence(timeout: playlistTimeout),
                      "Seeded '\(name)' never appeared")
        playlistRow.tap()

        let playAll = app.buttons["playlist.playAll"]
        XCTAssertTrue(playAll.waitForExistence(timeout: 10),
                      "'Play All' never appeared in \(name)")
        playAll.tap()

        let playPause = app.buttons["np.playpause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10),
                      "Now Playing / play-pause control never appeared for \(name)")
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 10),
                      "Tapping Play All did not start playback for \(name)")
        if let expectedTrack {
            XCTAssertTrue(app.staticTexts[expectedTrack].waitForExistence(timeout: 10),
                          "Now Playing did not show \(expectedTrack)")
        }

        if requireElapsedAdvance {
            let elapsed = app.staticTexts["np.elapsed"]
            XCTAssertTrue(elapsed.waitForExistence(timeout: 10),
                          "Elapsed time label did not render for \(name)")
            XCTAssertTrue(waitForElapsedAdvance(elapsed, timeout: 20),
                          "Playback time did not advance for \(name)")
        }
    }

    /// Polls an element's accessibility `value` until it matches, or times out.
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

    private func waitForElapsedAdvance(_ element: XCUIElement,
                                       timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (element.value as? String) ?? element.label
            if value != "0:00" && !value.isEmpty { return true }
            usleep(200_000)
        }
        let value = (element.value as? String) ?? element.label
        return value != "0:00" && !value.isEmpty
    }

    private func closeNowPlaying(_ app: XCUIApplication) {
        let close = app.buttons["Close"]
        if close.exists {
            close.tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    /// Taps the nav back button until the root list is showing.
    private func popToRoot(_ app: XCUIApplication) {
        var hops = 0
        while !app.buttons["root.playlists"].exists && hops < 6 {
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
            hops += 1
        }
    }
}
