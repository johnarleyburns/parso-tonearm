import XCTest

/// The single watchOS simulator smoke test for Platterhead. Verifies the app
/// boots, seeded fixtures render, and — critically — that tapping "Play All"
/// actually starts playback, that the elapsed clock advances, and that
/// play/pause toggles the real transport state. Run locally; CI runs
/// `swift test` only.
///
/// **Every fixture here is bundled audio; this test never touches the network.**
/// It used to play two archive.org tracks — one streamed, one downloaded at seed
/// time — and on 2026-08-16 archive.org started returning HTTP 500 for that
/// item's media while its metadata endpoint stayed up. Playback dutifully
/// reported `playing`, no bytes arrived, the elapsed label sat at 0:00, and
/// because this test runs in the pre-commit hook it **blocked every commit in
/// the repository** for a reason that had nothing to do with any change being
/// made. A gate on our own code must not be closable by a third party's outage.
/// Live remote servers belong to the UI regression suite (§53), which is run by
/// hand and skips honestly when a prerequisite is missing.
final class WatchSmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWatchSmokeBootsPlaysAndBrowses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "SEED_WATCH_FIXTURES"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        // The transport assertion the archive.org playlists used to carry: a
        // local WAV whose elapsed clock has to actually move. A dead transport
        // reports `playing` just as convincingly as a live one, so this — not
        // the button's own state — is what catches it.
        playPlaylist(app,
                     name: "Built-in Playlist",
                     expectedTrack: nil,
                     playlistTimeout: 10,
                     requireElapsedAdvance: true)

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

        // The downloaded-and-pinned shape: a second playlist, browsed to from the
        // root, holding one track whose audio is already on the watch and whose
        // real byte size is in the manifest. No seed-time download — the file is
        // copied out of the app bundle.
        playPlaylist(app,
                     name: "Pinned Track Smoke",
                     expectedTrack: "ambient-ocean",
                     playlistTimeout: 15,
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
