import Testing
@testable import TonearmWatchCore

/// Watch collection detail's Play and Shuffle buttons must agree on whether anything is playable —
/// otherwise a tap that reaches `play(...)` (Shuffle had no disabled check at all) falls through to
/// the T2 target-choice sheet with every option disabled, a dead end discovered while removing the
/// §7.5/.iPhone dead code.
@Suite struct WatchCollectionPlaybackPolicyTests {
    @Test func testDisabledWhenNeitherTargetCanPlay() {
        #expect(!WatchCollectionPlaybackPolicy.canStartPlayback(canPlayOnPhone: false, canPlayOnWatch: false))
    }

    @Test func testEnabledWhenWatchCanPlay() {
        #expect(WatchCollectionPlaybackPolicy.canStartPlayback(canPlayOnPhone: false, canPlayOnWatch: true))
    }

    @Test func testEnabledWhenPhoneCanPlay() {
        #expect(WatchCollectionPlaybackPolicy.canStartPlayback(canPlayOnPhone: true, canPlayOnWatch: false))
    }

    @Test func testEnabledWhenBothCanPlay() {
        #expect(WatchCollectionPlaybackPolicy.canStartPlayback(canPlayOnPhone: true, canPlayOnWatch: true))
    }
}
