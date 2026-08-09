import XCTest

/// Now Playing lanes of the UI regression suite (spec §53.3, §52).
///
/// STATUS: scaffolded. See the header of `RemoteLibraryRegressionUITests` for the
/// skip-vs-fail contract.
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
        // TODO(D-1): start playback, open Now Playing, then for every control in
        // the primary row assert `frame` is contained by the window's safe area
        // inset by the screen margin, and that `isHittable` is true.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-1")
    }

    /// D-1 · The six primary actions are on screen and hittable.
    func testPrimaryActionsArePresentAndHittable() throws {
        app = .launchForRegression()
        // TODO(D-1, D-4, D-5): np.favorite, np.addToPlaylist, np.download,
        // np.watchDownload, np.airplay, np.overflow — all hittable (§52.2).
        throw XCTSkip("scaffolded — body pending; see spec §51 D-1, D-4, D-5")
    }

    /// D-2 · Artwork is never covered by a "Tap to Change" affordance, and
    /// changing artwork lives in the overflow menu instead.
    func testArtworkHasNoOverlayAndArtworkActionsLiveInOverflow() throws {
        app = .launchForRegression()
        // TODO(D-2): assert no element identified "np.artwork.tapToChange" exists,
        // then open np.overflow and assert "Change Artwork" is offered there.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-2")
    }

    /// D-3 · The Watch control performs "Download to Watch".
    func testWatchControlDownloadsToWatch() throws {
        app = .launchForRegression()
        // TODO(D-3): tap np.watchDownload, assert the glyph enters the
        // transferring state and the action is announced to VoiceOver.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-3")
    }

    /// D-4 · Add to Playlist is reachable from Now Playing and actually adds.
    func testAddToPlaylistFromNowPlaying() throws {
        app = .launchForRegression()
        // TODO(D-4): np.addToPlaylist ▸ pick a playlist ▸ assert the track is in
        // that playlist's rows afterwards.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-4")
    }

    /// D-5 · Download to phone is reachable from Now Playing and changes state.
    func testDownloadToPhoneFromNowPlaying() throws {
        app = .launchForRegression()
        throw XCTSkip("scaffolded — body pending; see spec §51 D-5")
    }

    /// D-6 · The overflow menu carries exactly the secondary actions §52.2 assigns
    /// to it — no more, so the menu does not become the new dumping ground.
    func testOverflowMenuContainsExactlySecondaryActions() throws {
        app = .launchForRegression()
        throw XCTSkip("scaffolded — body pending; see spec §51 D-6")
    }

    /// D-6 · Controls meet the 44 pt minimum hit target.
    func testControlsMeetMinimumHitTarget() throws {
        app = .launchForRegression()
        // TODO(D-6): assert every primary control's frame is at least 44×44 pt.
        // The pre-fix toolbar used 36 pt, below Apple's documented minimum.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-6")
    }
}
