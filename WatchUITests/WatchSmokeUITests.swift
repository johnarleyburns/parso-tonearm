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

    func testWatchAppBootsPlaysAndBrowses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "SEED_WATCH_FIXTURES"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let rootPlaylists = app.buttons["root.playlists"]
        XCTAssertTrue(rootPlaylists.waitForExistence(timeout: 10),
                      "Root did not render the Playlists row")
        rootPlaylists.tap()

        let playlistRow = app.staticTexts["Built-in Playlist"]
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 10),
                      "Seeded 'Built-in Playlist' never appeared")
        playlistRow.tap()

        // Tap "Play All" (not `buttons.firstMatch`, which resolves to the nav
        // BackButton). The button appears once the playlist's tracks load.
        let playAll = app.buttons["playlist.playAll"]
        XCTAssertTrue(playAll.waitForExistence(timeout: 10),
                      "'Play All' never appeared in the playlist detail")
        playAll.tap()

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
        app.navigationBars.buttons.firstMatch.tap()
        popToRoot(app)

        // Storage shows the live iPhone connection status.
        let rootStorage = app.buttons["root.storage"]
        XCTAssertTrue(rootStorage.waitForExistence(timeout: 5))
        rootStorage.tap()
        let phoneStatus = app.staticTexts["storage.phoneStatus"]
        XCTAssertTrue(phoneStatus.waitForExistence(timeout: 5),
                      "Storage screen did not render the iPhone status")
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
