#if !os(watchOS)
import AppIntents
import Testing
@testable import TonearmCore

/// Pins the two properties that decide whether a playback intent works
/// hands-free over CarPlay: it is an `AudioPlaybackIntent`, and it never asks
/// to foreground the app (Siri refuses that while driving — "Sorry, I can't
/// do that while you're driving"). See docs/plans/carplay-search-ios27-handoff.md.
@Suite struct CarPlaySafeIntentsTests {
    private let playbackIntents: [any AudioPlaybackIntent.Type] = [
        TonearmPlayPlaylistIntent.self,
        TonearmPlayArtistIntent.self,
        TonearmPlaySongIntent.self,
        TonearmResumeIntent.self
    ]

    @Test func testPlaybackIntentsNeverForegroundTheApp() {
        for intent in playbackIntents {
            let opensApp = intent.openAppWhenRun
            #expect(!opensApp, "\(intent) must run without opening the app")
        }
    }
}
#endif
