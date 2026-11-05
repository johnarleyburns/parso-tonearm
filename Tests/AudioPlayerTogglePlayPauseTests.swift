#if !os(watchOS)
import AVFoundation
import XCTest
@testable import TonearmCore

/// Regression for two real reports in sequence on the mini-player's play/pause button:
///
/// 1. "Sometimes needs 3-4 taps before anything happens": a play request on a remote/streamed
///    track sits in `.waitingToPlayAtSpecifiedRate` while buffering, but `AudioPlayer.isPlaying`
///    optimistically flipped to true the instant `play()` was called — so an impatient repeat
///    tap during that window read the optimistic `isPlaying` and called `pause()`, canceling the
///    still-pending play before it ever started.
/// 2. After fixing (1) by ignoring every toggle during `.waitingToPlayAtSpecifiedRate`: "rarely
///    does anything" — that status also recurs on a mid-track re-buffer of an *already-playing*
///    remote track, not just a track's first play(), so a genuine pause tap went unresponsive
///    for as long as the re-buffer lasted.
///
/// `AudioPlayer.shouldIgnoreToggle(timeControlStatus:confirmedGeneration:loadGeneration:)` is the
/// exact decision `togglePlayPause()` now makes before touching `isPlaying` at all. A real
/// `AVPlayer` only reaches `.waitingToPlayAtSpecifiedRate` through genuine network buffering,
/// which a unit test can't force deterministically — this pins down the decision function
/// directly instead, over every combination of status and generation match/mismatch.
@MainActor
final class AudioPlayerTogglePlayPauseTests: XCTestCase {
    func testIgnoresOnlyAStillUnconfirmedFirstPlayWaitingToStart() {
        // Track just loaded, never once confirmed advancing (confirmedGeneration != loadGeneration)
        // — the original bug: a tap here could cancel the still-pending first play.
        XCTAssertTrue(
            AudioPlayer.shouldIgnoreToggle(
                timeControlStatus: .waitingToPlayAtSpecifiedRate, confirmedGeneration: 0, loadGeneration: 1),
            "a tap during this track's still-unconfirmed first play must not reach pause()/play()")
        XCTAssertFalse(
            AudioPlayer.shouldIgnoreToggle(
                timeControlStatus: .paused, confirmedGeneration: 0, loadGeneration: 1),
            "a confirmed-paused player must still respond to a tap even before any confirmed play")
        XCTAssertFalse(
            AudioPlayer.shouldIgnoreToggle(
                timeControlStatus: .playing, confirmedGeneration: 0, loadGeneration: 1),
            "a confirmed-playing player must still respond to a tap")
    }

    func testNeverIgnoresAToggleOnceTheTrackHasBeenConfirmedPlayingAtLeastOnce() {
        // Real report #2: an already-confirmed-playing track re-buffers mid-stream, revisiting
        // .waitingToPlayAtSpecifiedRate — a pause tap here must go through immediately, since
        // there is no longer a pending *first* play left to protect.
        XCTAssertFalse(
            AudioPlayer.shouldIgnoreToggle(
                timeControlStatus: .waitingToPlayAtSpecifiedRate, confirmedGeneration: 2, loadGeneration: 2),
            "a re-buffer on an already-confirmed-playing track must not block a pause tap")
        XCTAssertFalse(
            AudioPlayer.shouldIgnoreToggle(
                timeControlStatus: .paused, confirmedGeneration: 2, loadGeneration: 2))
        XCTAssertFalse(
            AudioPlayer.shouldIgnoreToggle(
                timeControlStatus: .playing, confirmedGeneration: 2, loadGeneration: 2))
    }
}
#endif
