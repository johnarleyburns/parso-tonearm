import AVFoundation
import Testing
@testable import TonearmCore

extension SharedProductionSingletonTests {
    /// Architecture-review finding: `seek(to:)` wrote `currentTime` unclamped. A scrub (or any other
    /// caller) computed against a since-corrected/inflated duration estimate could seek past the
    /// item's real end, which ends it and silently triggers `next()`.
    @MainActor
    @Suite final class AudioPlayerSeekClampTests {
        isolated deinit {
            let p = AudioPlayer.shared
            p.duration = 0
            p.currentTime = 0
        }

        @Test func testSeekClampsPastEndToTheKnownDuration() {
            let player = AudioPlayer.shared
            player.duration = 180
            player.seek(to: 500)
            #expect(player.currentTime == 180)
        }

        @Test func testSeekClampsNegativeToZero() {
            let player = AudioPlayer.shared
            player.duration = 180
            player.seek(to: -5)
            #expect(player.currentTime == 0)
        }

        @Test func testSeekWithinBoundsIsUnaffected() {
            let player = AudioPlayer.shared
            player.duration = 180
            player.seek(to: 90)
            #expect(player.currentTime == 90)
        }

        @Test func testSeekWithUnknownDurationOnlyClampsNegative() {
            let player = AudioPlayer.shared
            player.duration = 0
            player.seek(to: 500)
            #expect(player.currentTime == 500, "with no known duration there is nothing to clamp against but zero")
            player.seek(to: -5)
            #expect(player.currentTime == 0)
        }
    }
}
