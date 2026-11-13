import XCTest
@testable import TonearmWatchCore

/// Watch collection detail's Play and Shuffle buttons must agree on whether anything is playable —
/// otherwise a tap that reaches `play(...)` (Shuffle had no disabled check at all) falls through to
/// the T2 target-choice sheet with every option disabled, a dead end discovered while removing the
/// §7.5/.iPhone dead code.
final class WatchCollectionPlaybackPolicyTests: XCTestCase {
    func testDisabledWhenNeitherTargetCanPlay() {
        XCTAssertFalse(WatchCollectionPlaybackPolicy.canStartPlayback(canPlayOnPhone: false, canPlayOnWatch: false))
    }

    func testEnabledWhenWatchCanPlay() {
        XCTAssertTrue(WatchCollectionPlaybackPolicy.canStartPlayback(canPlayOnPhone: false, canPlayOnWatch: true))
    }

    func testEnabledWhenPhoneCanPlay() {
        XCTAssertTrue(WatchCollectionPlaybackPolicy.canStartPlayback(canPlayOnPhone: true, canPlayOnWatch: false))
    }

    func testEnabledWhenBothCanPlay() {
        XCTAssertTrue(WatchCollectionPlaybackPolicy.canStartPlayback(canPlayOnPhone: true, canPlayOnWatch: true))
    }
}
