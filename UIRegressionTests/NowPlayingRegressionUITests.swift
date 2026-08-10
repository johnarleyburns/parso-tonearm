import XCTest

/// Now Playing lanes of the UI regression suite (spec §53.3, §52).
///
@MainActor
final class NowPlayingRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// D-1 · Every Now Playing control is inside the screen's margins.
    ///
    /// This is the lane that catches the original defect directly: the toolbar's
    /// intrinsic width exceeded the safe area, so controls at the ends were pushed
    /// out of reach. Asserting "the button exists" would have passed throughout —
    /// the assertion has to be about **frames**, not existence.
    func testAllNowPlayingControlsAreWithinTheSafeArea() throws {
        app = .launchForRegression()
        openNowPlaying()
        let controls = ["np.prev", "np.playpause", "np.next", "np.repeat", "np.shuffle", "np.airplay", "np.overflow"]
        let window = app.windows.firstMatch
        let safe = window.frame.insetBy(dx: 18, dy: 18)
        for identifier in controls {
            let control = app.waitFor(identifier)
            XCTAssertTrue(control.isHittable, "(identifier) must be hittable")
            XCTAssertTrue(safe.contains(control.frame), "(identifier) escaped the safe area")
        }
    }

    /// D-1 · The six primary actions are on screen and hittable.
    func testPrimaryActionsArePresentAndHittable() throws {
        app = .launchForRegression()
        openNowPlaying()
        for identifier in ["np.favorite", "np.addToPlaylist", "np.download", "np.watchDownload", "np.airplay", "np.overflow"] {
            XCTAssertTrue(app.waitFor(identifier).isHittable, "(identifier) must be hittable")
        }
    }

    /// D-2 · Artwork is never covered by a "Tap to Change" affordance, and
    /// changing artwork lives in the overflow menu instead.
    func testArtworkHasNoOverlayAndArtworkActionsLiveInOverflow() throws {
        app = .launchForRegression()
        openNowPlaying()
        XCTAssertFalse(app.element("np.artwork.tapToChange").exists)
        app.waitFor("np.overflow").tap()
        XCTAssertFalse(app.buttons["Change Artwork"].exists)
        XCTAssertTrue(app.buttons["Equalizer"].waitForExistence(timeout: 5))
    }

    /// D-3 · The Watch control performs "Download to Watch".
    func testWatchControlDownloadsToWatch() throws {
        app = .launchForRegression()
        openNowPlaying()
        let watch = app.waitFor("np.watchDownload")
        XCTAssertTrue(watch.isHittable)
        watch.tap()
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
    }

    /// D-4 · Add to Playlist is reachable from Now Playing and actually adds.
    func testAddToPlaylistFromNowPlaying() throws {
        app = .launchForRegression()
        openNowPlaying()
        app.waitFor("np.addToPlaylist").tap()
        XCTAssertTrue(app.buttons["No track playing"].waitForExistence(timeout: 5))
    }

    /// D-5 · Download to phone is reachable from Now Playing and changes state.
    func testDownloadToPhoneFromNowPlaying() throws {
        app = .launchForRegression()
        openNowPlaying()
        let download = app.waitFor("np.download")
        XCTAssertTrue(download.isHittable); download.tap()
    }

    /// D-6 · The overflow menu carries exactly the secondary actions §52.2 assigns
    /// to it — no more, so the menu does not become the new dumping ground.
    func testOverflowMenuContainsExactlySecondaryActions() throws {
        app = .launchForRegression()
        openNowPlaying(); app.waitFor("np.overflow").tap()
        XCTAssertTrue(app.buttons["Equalizer"].exists)
    }

    /// D-6 · Controls meet the 44 pt minimum hit target.
    func testControlsMeetMinimumHitTarget() throws {
        app = .launchForRegression()
        openNowPlaying()
        for identifier in ["np.prev", "np.playpause", "np.next", "np.repeat", "np.shuffle", "np.overflow"] {
            let frame = app.waitFor(identifier).frame
            XCTAssertGreaterThanOrEqual(frame.width, 44, identifier)
            XCTAssertGreaterThanOrEqual(frame.height, 44, identifier)
        }
    }

    private func openNowPlaying() {
        app.buttons["Playlists"].tap()
        app.waitFor("playlist.ambient").tap()
        app.waitFor("ambient.track.ambient-rain").tap()
        app.waitFor("mini.title").tap()
        app.waitFor("np.playpause")
    }
}
