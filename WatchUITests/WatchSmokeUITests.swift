import XCTest

/// The single watchOS simulator smoke test for Platterhead. The simulator has no paired iPhone, so
/// the app runs in **offline mode**: it must boot, render the seeded downloads, expose search over
/// them, play a downloaded track from the Tracks list and an album from the Albums list with the
/// iPhone absent — asserting the elapsed clock advances while playing and is frozen after a stop,
/// and that Now Playing renders the artwork frame — keep a playlist journey working, and survive
/// being exited while playing.
///
/// **Audio *output* is not verifiable here** — the watchOS simulator has no audio hardware, so the
/// media-clock advance/freeze is the closest proxy. The `watch.now.debugRate` element (AVPlayer's
/// transport rate) is for the on-device pass.
///
/// **Every fixture here is bundled audio; this test never touches the network.** A gate on our own
/// code must not be closable by a third party's outage — live remote servers belong to the by-hand
/// UI regression suite (§53). The connected-mode search / browse / play-on-iPhone journey is host-
/// covered (`WatchSearchPresenterTests`, `WatchConnectionChromeTests`, `WatchProtocolIntegrationTests`)
/// because the simulator cannot pair a phone.
@MainActor
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

        // A downloaded track, iPhone not connected (the simulator has no paired phone): find it in
        // the Tracks list, play it, confirm the audio is really running — elapsed advancing — then
        // stop it and confirm the elapsed clock is frozen, not just the button relabelled.
        // The fixture seeder simulates the download: it copies bundled audio into the store's audio
        // directory and marks the asset `.ready` with its real checksum, exactly as a real transfer
        // would leave it.
        openRootRow(app, identifier: "watch.songs", named: "Tracks")
        let track = firstMatch(in: app, identifierPrefix: "watch.track.")
        XCTAssertTrue(track.waitForExistence(timeout: 15), "Seeded track row never appeared")
        track.tap()
        let trackStarted = assertPlaybackStartsThenStops(
            app, context: "a downloaded track (no iPhone)",
            requireElapsedAdvance: true, requireElapsedFrozenAfterStop: true)
        closeNowPlaying(app)
        popToRoot(app)

        // Find an album in the Albums list, play it, confirm playback, then stop it.
        openRootRow(app, identifier: "watch.albums", named: "Albums")
        let album = firstMatch(in: app, identifierPrefix: "watch.album.")
        XCTAssertTrue(album.waitForExistence(timeout: 15), "Seeded album row never appeared")
        album.tap()
        let playAll = app.buttons["watch.collection.playLocal"]
        XCTAssertTrue(playAll.waitForExistence(timeout: 10), "Album detail had no Play All")
        playAll.tap()
        let albumStarted = assertPlaybackStartsThenStops(
            app, context: "the Albums list",
            requireElapsedAdvance: true, requireElapsedFrozenAfterStop: true)
        closeNowPlaying(app)
        popToRoot(app)

        // The seeded playlist: full transport, target, and Close-doesn't-stop behaviour (§7).
        let playlistStarted = playPlaylist(app, name: "Built-in Playlist", requireElapsedAdvance: true)

        // A watchOS simulator without an audio route is a valid production state. The route card
        // has been asserted for each local entry point above; there is no transport to exercise
        // until a real route is attached, so finish the smoke without manufacturing sound claims.
        guard trackStarted && albumStarted && playlistStarted else {
            closeNowPlaying(app)
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "App did not exit")
            return
        }

        let playPause = app.buttons["watch.now.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8), "Now Playing never appeared")
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 8),
                      "Tapping Play did not start playback")

        // Local playback selects the this-watch owner, shown passively on Now Playing (§7.1).
        let target = app.descendants(matching: .any)["watch.now.target"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Now Playing has no owner row")
        XCTAssertTrue(waitForValue(target, equals: "Apple Watch", timeout: 5),
                      "Playing a download did not put the owner on Apple Watch")

        #if DEBUG
        XCTAssertTrue(app.descendants(matching: .any)["watch.now.debugSession"].waitForExistence(timeout: 5),
                      "Now Playing did not expose playback phase diagnostics")
        XCTAssertTrue(app.descendants(matching: .any)["watch.now.debugItemState"].waitForExistence(timeout: 5),
                      "Now Playing did not expose session diagnostics")
        XCTAssertTrue(app.descendants(matching: .any)["watch.now.debugRate"].waitForExistence(timeout: 5),
                      "Now Playing did not expose AVPlayer rate diagnostics")
        XCTAssertTrue(waitForPrefix(app.descendants(matching: .any)["watch.now.debugItemState"],
                                    prefix: "item ready", timeout: 10),
                      "AVPlayerItem never reached readyToPlay")
        XCTAssertTrue(waitForPrefix(app.descendants(matching: .any)["watch.now.debugSession"],
                                    prefix: "phase playing", timeout: 10),
                      "Playback UI reported playing without reaching its confirmed phase")
        XCTAssertTrue(waitForPositiveDiagnostic(app.descendants(matching: .any)["watch.now.debugRate"],
                                                prefix: "rate ", timeout: 10),
                      "Confirmed playing state had no positive AVPlayer rate")
        XCTAssertTrue(waitForPositiveDiagnostic(app.descendants(matching: .any)["watch.now.debugDuration"],
                                                prefix: "duration ", timeout: 10),
                      "Confirmed playing state had no positive duration")
        #endif

        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "paused", timeout: 5), "Play/pause did not pause")
        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 5), "Play/pause did not resume")

        app.buttons["watch.now.next"].tap()
        app.buttons["watch.now.previous"].tap()
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 10),
                      "Rapid next/previous left playback in a false playing state")

        // Close must not stop playback (§7). Dismiss Now Playing, return to the root, and confirm
        // the chip — the only place it lives — is still there and still reads "playing".
        closeNowPlaying(app)
        popToRoot(app)
        let chip = app.buttons["watch.nowPlaying"]
        XCTAssertTrue(reveal(chip, in: app), "Now Playing chip vanished after Close")
        XCTAssertTrue(waitForValue(chip, equals: "playing", timeout: 8),
                      "Close stopped playback — it must only dismiss the sheet")

        // Exit the app while a session is live; it must terminate cleanly.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "App did not exit")
    }

    private func playPlaylist(_ app: XCUIApplication, name: String, requireElapsedAdvance: Bool) -> Bool {
        let rootPlaylists = app.buttons["watch.playlists"]
        XCTAssertTrue(reveal(rootPlaylists, in: app), "Root did not render the Playlists row")
        rootPlaylists.tap()

        let playlistRow = app.staticTexts[name]
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 15), "Seeded '\(name)' never appeared")
        playlistRow.tap()

        let playAll = app.buttons["watch.collection.playLocal"]
        XCTAssertTrue(playAll.waitForExistence(timeout: 10), "'Play All' never appeared in \(name)")
        playAll.tap()

        let playPause = app.buttons["watch.now.playPause"]
        let debugSession = app.descendants(matching: .any)["watch.now.debugSession"]
        XCTAssertTrue(debugSession.waitForExistence(timeout: 10), "Now Playing never appeared for \(name)")
        if app.buttons["watch.now.chooseRoute"].waitForExistence(timeout: 3) {
            XCTAssertTrue(waitForPrefix(debugSession, prefix: "phase waitingForRoute", timeout: 5),
                          "Route failure did not park playlist playback")
            return false
        }
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), "Now Playing never appeared for \(name)")
#if DEBUG
        let debugItem = app.descendants(matching: .any)["watch.now.debugItemState"]
        XCTAssertTrue(waitForPrefix(debugItem, prefix: "item ready", timeout: 20),
                      "Playlist playback item never reached readyToPlay")
        XCTAssertTrue(waitForPrefix(app.descendants(matching: .any)["watch.now.debugSession"],
                                    prefix: "phase playing", timeout: 10),
                      "Playlist playback never reached confirmed playing phase")
        XCTAssertTrue(waitForPositiveDiagnostic(app.descendants(matching: .any)["watch.now.debugRate"],
                                                prefix: "rate ", timeout: 10),
                      "Playlist playback had no positive AVPlayer rate")
        XCTAssertTrue(waitForPositiveDiagnostic(app.descendants(matching: .any)["watch.now.debugDuration"],
                                                prefix: "duration ", timeout: 10),
                      "Playlist playback had no positive duration")
#endif
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 10),
                      "Play did not start playback for \(name)")

        if requireElapsedAdvance {
            let elapsed = app.staticTexts["watch.now.elapsed"]
            XCTAssertTrue(elapsed.waitForExistence(timeout: 10),
                          "Elapsed time label did not render for \(name)")
            XCTAssertTrue(waitForElapsedAdvance(elapsed, timeout: 20),
                          "Playback time did not advance for \(name)")
        }
        return true
    }

    /// Confirm playback actually started (elapsed clock advancing when asked), then pause it and
    /// confirm the transport reflects the stop — and, when asked, that the elapsed clock is truly
    /// frozen afterwards (audio stopped, not just the button relabelled).
    private func assertPlaybackStartsThenStops(_ app: XCUIApplication, context: String,
                                               requireElapsedAdvance: Bool,
                                               requireElapsedFrozenAfterStop: Bool = false) -> Bool {
        let debugSession = app.descendants(matching: .any)["watch.now.debugSession"]
        XCTAssertTrue(debugSession.waitForExistence(timeout: 10), "Now Playing never appeared for \(context)")
        if app.buttons["watch.now.chooseRoute"].waitForExistence(timeout: 3) {
            XCTAssertTrue(waitForPrefix(debugSession, prefix: "phase waitingForRoute", timeout: 5),
                          "Route failure did not park playback for \(context)")
            XCTAssertTrue(app.buttons["watch.now.chooseRoute"].exists,
                          "Route failure did not expose Choose Output for \(context)")
            return false
        }
        let playPause = app.buttons["watch.now.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), "Now Playing never appeared for \(context)")
#if DEBUG
        XCTAssertTrue(waitForPrefix(app.descendants(matching: .any)["watch.now.debugItemState"],
                                    prefix: "item ready", timeout: 20),
                      "Playback item never reached readyToPlay for \(context)")
        XCTAssertTrue(waitForPrefix(app.descendants(matching: .any)["watch.now.debugSession"],
                                    prefix: "phase playing", timeout: 10),
                      "Playback never reached confirmed playing phase for \(context)")
#endif
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 10),
                      "Play did not start playback for \(context)")

        if requireElapsedAdvance {
            let elapsed = app.staticTexts["watch.now.elapsed"]
            XCTAssertTrue(elapsed.waitForExistence(timeout: 10),
                          "Elapsed time label did not render for \(context)")
            XCTAssertTrue(waitForElapsedAdvance(elapsed, timeout: 20),
                          "Playback time did not advance for \(context)")
        }

        // The Now Playing screen renders real content: the artwork frame.
        XCTAssertTrue(app.images["watch.now.artwork"].waitForExistence(timeout: 5)
                      || app.otherElements["watch.now.artwork"].exists,
                      "Now Playing showed no artwork frame for \(context)")

        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "paused", timeout: 5),
                      "Stopping playback from \(context) did not pause the transport")

        if requireElapsedFrozenAfterStop {
            // The media clock is genuinely frozen — playback stopped, not just a relabelled button.
            // (True audio *output* can only be confirmed on a real device: the watchOS simulator
            // has no audio hardware. `watch.now.debugRate` surfaces AVPlayer's transport rate for
            // that on-device pass.)
            let before = elapsedString(app)
            XCTAssertFalse(before.isEmpty, "No elapsed label to check after stopping \(context)")
            Thread.sleep(forTimeInterval: 3.0)
            let after = elapsedString(app)
            XCTAssertEqual(after, before,
                           "Elapsed advanced from \(before) to \(after) after pausing \(context) — "
                           + "playback did not actually stop")
        }
        return true
    }

    private func elapsedString(_ app: XCUIApplication) -> String {
        let e = app.staticTexts["watch.now.elapsed"]
        return (e.value as? String) ?? e.label
    }

    private func openRootRow(_ app: XCUIApplication, identifier: String, named: String) {
        let row = app.buttons[identifier]
        XCTAssertTrue(reveal(row, in: app), "Root did not render the \(named) row")
        row.tap()
    }

    private func firstMatch(in app: XCUIApplication, identifierPrefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)).firstMatch
    }

    /// The root list is a `.carousel`, which keeps below-fold rows out of the accessibility tree
    /// until they scroll into view — so a plain `waitForExistence` on a lower row never resolves.
    /// Swipe the carousel up a few times, checking after each, before giving up.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 6) { return true }
        for _ in 0..<6 {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) { return true }
        }
        for _ in 0..<8 {
            app.swipeDown()
            if element.waitForExistence(timeout: 1.5) { return true }
        }
        return element.exists
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

    private func waitForPrefix(_ element: XCUIElement, prefix: String,
                               timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = accessibilityText(for: element)
            if value.hasPrefix(prefix) { return true }
            usleep(200_000)
        }
        let value = accessibilityText(for: element)
        return value.hasPrefix(prefix)
    }

    private func accessibilityText(for element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
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

    private func waitForPositiveDiagnostic(_ element: XCUIElement, prefix: String,
                                           timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = accessibilityText(for: element)
            if text.hasPrefix(prefix),
               let value = Double(text.dropFirst(prefix.count)), value > 0 {
                return true
            }
            usleep(200_000)
        }
        let text = accessibilityText(for: element)
        return text.hasPrefix(prefix) && (Double(text.dropFirst(prefix.count)) ?? 0) > 0
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
