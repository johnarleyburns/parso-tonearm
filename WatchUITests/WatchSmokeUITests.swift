import XCTest

/// The single watchOS simulator smoke test for Platterhead. The simulator has no paired iPhone, so
/// the app runs in **offline mode**: it must boot, render the seeded downloads, search them locally,
/// and — critically — actually start playback from a local file with the elapsed clock advancing and
/// the transport toggling both ways.
///
/// **Every fixture here is bundled audio; this test never touches the network.** A gate on our own
/// code must not be closable by a third party's outage — live remote servers belong to the by-hand
/// UI regression suite (§53). The connected-mode search / browse / play-on-iPhone journey is host-
/// covered (`WatchSearchPresenterTests`, `WatchConnectionChromeTests`, `WatchProtocolIntegrationTests`)
/// because the simulator cannot pair a phone.
final class WatchSmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWatchSmokeBootsPlaysSearchesAndBrowses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "SEED_WATCH_FIXTURES"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.otherElements["watch.root"].waitForExistence(timeout: 10)
                      || app.collectionViews.firstMatch.waitForExistence(timeout: 10),
                      "Root never rendered")

        // The search surface opens with its field. (watchOS full-screen text entry is not
        // scriptable in XCUITest; the typed-query state machine is host-covered by
        // WatchSearchPresenterTests.)
        let search = app.buttons["watch.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Root did not render the Search row")
        search.tap()
        XCTAssertTrue(app.textFields["watch.search.field"].waitForExistence(timeout: 8),
                      "Search field never appeared")
        popToRoot(app)

        // Play the seeded playlist and confirm real playback.
        playPlaylist(app, name: "Built-in Playlist", requireElapsedAdvance: true)

        let playPause = app.buttons["watch.now.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8), "Now Playing never appeared")
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 8),
                      "Tapping Play did not start playback")

        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "paused", timeout: 5), "Play/pause did not pause")
        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 5), "Play/pause did not resume")

        app.buttons["watch.now.next"].tap()
        app.buttons["watch.now.previous"].tap()

        closeNowPlaying(app)
        popToRoot(app)

        // The second seeded playlist, browsed to from the root.
        playPlaylist(app, name: "Pinned Track Smoke", requireElapsedAdvance: true)
        closeNowPlaying(app)
        popToRoot(app)

        // Back at a usable offline root.
        XCTAssertTrue(app.buttons["watch.search"].waitForExistence(timeout: 10)
                      || app.buttons["watch.playlists"].waitForExistence(timeout: 10),
                      "Did not return to the offline root after the fixture journey")
    }

    private func playPlaylist(_ app: XCUIApplication, name: String, requireElapsedAdvance: Bool) {
        let rootPlaylists = app.buttons["watch.playlists"]
        XCTAssertTrue(rootPlaylists.waitForExistence(timeout: 10), "Root did not render the Playlists row")
        rootPlaylists.tap()

        let playlistRow = app.staticTexts[name]
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 15), "Seeded '\(name)' never appeared")
        playlistRow.tap()

        let playAll = app.buttons["watch.collection.playLocal"]
        XCTAssertTrue(playAll.waitForExistence(timeout: 10), "'Play All' never appeared in \(name)")
        playAll.tap()

        let playPause = app.buttons["watch.now.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), "Now Playing never appeared for \(name)")
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 10),
                      "Play did not start playback for \(name)")

        if requireElapsedAdvance {
            let elapsed = app.staticTexts["watch.now.elapsed"]
            XCTAssertTrue(elapsed.waitForExistence(timeout: 10),
                          "Elapsed time label did not render for \(name)")
            XCTAssertTrue(waitForElapsedAdvance(elapsed, timeout: 20),
                          "Playback time did not advance for \(name)")
        }
    }

    private func waitForValue(_ element: XCUIElement, equals expected: String,
                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == expected { return true }
            usleep(200_000)
        }
        return (element.value as? String) == expected
    }

    private func waitForElapsedAdvance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
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
        if close.exists { close.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
    }

    private func popToRoot(_ app: XCUIApplication) {
        var hops = 0
        while !app.buttons["watch.playlists"].exists && !app.buttons["watch.search"].exists && hops < 6 {
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
            hops += 1
        }
    }
}
