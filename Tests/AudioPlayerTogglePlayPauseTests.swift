#if !os(watchOS)
import AVFoundation
import XCTest
@testable import TonearmCore

/// Regression for the real report "the mini-player's play/pause button sometimes needs 3-4
/// taps before anything happens": a play request on a remote/streamed track sits in
/// `.waitingToPlayAtSpecifiedRate` while buffering, but `AudioPlayer.isPlaying` optimistically
/// flipped to true the instant `play()` was called — so an impatient repeat tap during that
/// window read the optimistic `isPlaying` and called `pause()`, canceling the still-pending
/// play before it ever started.
///
/// `AudioPlayer.shouldIgnoreToggle(timeControlStatus:)` is the exact decision
/// `togglePlayPause()` now makes before touching `isPlaying` at all. A real `AVPlayer` only
/// reaches `.waitingToPlayAtSpecifiedRate` through genuine network buffering, which a unit test
/// can't force deterministically — this pins down the decision function directly instead,
/// exhaustively over every case of the enum it switches on.
@MainActor
final class AudioPlayerTogglePlayPauseTests: XCTestCase {
    func testIgnoresToggleOnlyWhileWaitingToPlayAtSpecifiedRate() {
        XCTAssertTrue(AudioPlayer.shouldIgnoreToggle(timeControlStatus: .waitingToPlayAtSpecifiedRate),
                      "a tap during this exact window must not reach player.pause()/play() at all")
        XCTAssertFalse(AudioPlayer.shouldIgnoreToggle(timeControlStatus: .paused),
                       "a confirmed-paused player must still respond to a tap")
        XCTAssertFalse(AudioPlayer.shouldIgnoreToggle(timeControlStatus: .playing),
                       "a confirmed-playing player must still respond to a tap")
    }
}
#endif
