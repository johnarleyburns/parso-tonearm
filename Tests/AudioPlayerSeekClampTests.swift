import AVFoundation
import XCTest
@testable import TonearmCore

/// Architecture-review finding: `seek(to:)` wrote `currentTime` unclamped. A scrub (or any other
/// caller) computed against a since-corrected/inflated duration estimate could seek past the
/// item's real end, which ends it and silently triggers `next()`.
@MainActor
final class AudioPlayerSeekClampTests: XCTestCase {
    override func tearDown() {
        let p = AudioPlayer.shared
        p.duration = 0
        p.currentTime = 0
        super.tearDown()
    }

    func testSeekClampsPastEndToTheKnownDuration() {
        let player = AudioPlayer.shared
        player.duration = 180
        player.seek(to: 500)
        XCTAssertEqual(player.currentTime, 180)
    }

    func testSeekClampsNegativeToZero() {
        let player = AudioPlayer.shared
        player.duration = 180
        player.seek(to: -5)
        XCTAssertEqual(player.currentTime, 0)
    }

    func testSeekWithinBoundsIsUnaffected() {
        let player = AudioPlayer.shared
        player.duration = 180
        player.seek(to: 90)
        XCTAssertEqual(player.currentTime, 90)
    }

    func testSeekWithUnknownDurationOnlyClampsNegative() {
        let player = AudioPlayer.shared
        player.duration = 0
        player.seek(to: 500)
        XCTAssertEqual(player.currentTime, 500, "with no known duration there is nothing to clamp against but zero")
        player.seek(to: -5)
        XCTAssertEqual(player.currentTime, 0)
    }
}
