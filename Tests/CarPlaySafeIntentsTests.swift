#if !os(watchOS)
import AppIntents
import XCTest
@testable import TonearmCore

/// Pins the two properties that decide whether a playback intent works
/// hands-free over CarPlay: it is an `AudioPlaybackIntent`, and it never asks
/// to foreground the app (Siri refuses that while driving — "Sorry, I can't
/// do that while you're driving"). See docs/plans/carplay-search-ios27-handoff.md.
final class CarPlaySafeIntentsTests: XCTestCase {
    private let playbackIntents: [any AudioPlaybackIntent.Type] = [
        TonearmPlayPlaylistIntent.self,
        TonearmPlayArtistIntent.self,
        TonearmPlaySongIntent.self,
        TonearmResumeIntent.self
    ]

    func testPlaybackIntentsNeverForegroundTheApp() {
        for intent in playbackIntents {
            XCTAssertFalse(intent.openAppWhenRun, "\(intent) must run without opening the app")
        }
    }
}
#endif
