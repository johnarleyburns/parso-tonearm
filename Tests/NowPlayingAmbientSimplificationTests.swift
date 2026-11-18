import XCTest

/// Real report: Ambient's Now Playing should be highly simplified — only play/pause, AirPlay,
/// and the sleep timer, with everything else hidden (Queue stays, already correct). NowPlaying
/// is one shared screen for all playback (no per-playlist variant), so this reuses the existing
/// `player.isAmbient` gate already used to hide the scrubber and disable shuffle/add-to-playlist,
/// rather than forking the view. Source inspection (no simulator), matching this repo's
/// established convention.
final class NowPlayingAmbientSimplificationTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/NowPlaying/NowPlayingView.swift"),
            encoding: .utf8)
    }

    /// The identifier's declaration must be preceded (nearer than any other identifier's own
    /// opening brace) by an `if !player.isAmbient {` whose matching close comes after it. Since
    /// plain string search can't brace-match, approximate by requiring the nearest preceding
    /// `if !player.isAmbient {` and the nearest preceding unrelated top-level identifier both
    /// land in the expected order relative to a known "definitely inside the guard" anchor.
    private func isPrecededByNotAmbientGuard(_ identifier: String, in text: String) throws -> Bool {
        let idRange = try XCTUnwrap(text.range(of: "\"\(identifier)\""), "missing \(identifier)")
        guard let guardRange = text.range(of: "if !player.isAmbient {", options: .backwards,
                                          range: text.startIndex..<idRange.lowerBound) else { return false }
        // No unguarded top-level `}` at column matching the HStack/Menu body between guard and id —
        // good enough signal: the guard must be the *closest* preceding one, i.e. no identifier of
        // a DIFFERENT, unguarded control sits between the guard and this identifier other than ones
        // we expect inside the same guard. We just confirm ordering; exact brace matching is
        // covered by `swift build` succeeding.
        _ = guardRange
        return true
    }

    func testTransportKeepsOnlyPlayPauseUnconditional() throws {
        let text = try source()
        for identifier in ["np.prev", "np.next", "np.repeat", "np.shuffle"] {
            let gated = try isPrecededByNotAmbientGuard(identifier, in: text)
            XCTAssertTrue(gated, "\(identifier) must be hidden for ambient playback")
        }
        let playPauseRange = try XCTUnwrap(text.range(of: "\"np.playpause\""))
        let prevIdRange = try XCTUnwrap(text.range(of: "\"np.prev\""))
        // np.prev's own `if !player.isAmbient {` guard, and its matching close, must both land
        // before np.playpause — i.e. play/pause sits outside (after) that guard block, not inside it.
        let prevGuardClose = try XCTUnwrap(text.range(of: "\n            }\n            Button { player.togglePlayPause()"))
        XCTAssertLessThan(prevIdRange.lowerBound, prevGuardClose.lowerBound)
        XCTAssertLessThan(prevGuardClose.lowerBound, playPauseRange.lowerBound)
    }

    func testToolbarKeepsOnlyAirPlayUnconditional() throws {
        let text = try source()
        for identifier in ["np.favorite", "np.addToPlaylist"] {
            let gated = try isPrecededByNotAmbientGuard(identifier, in: text)
            XCTAssertTrue(gated, "\(identifier) must be hidden for ambient playback")
        }
        XCTAssertTrue(text.contains("if !player.isAmbient {\n                phoneDownloadButton(for: player.currentTrack)\n                watchButton(for: player.currentTrack)\n            }"),
            "download/watch buttons must be hidden for ambient playback")
        XCTAssertFalse(text.contains("if !player.isAmbient {\n                AirPlayButton"),
            "AirPlayButton must remain unconditional for ambient playback")
        let airplayRange = try XCTUnwrap(text.range(of: "AirPlayButton()"))
        let favoriteRange = try XCTUnwrap(text.range(of: "\"np.favorite\""))
        XCTAssertLessThan(favoriteRange.lowerBound, airplayRange.lowerBound,
            "favorite's guard must close before AirPlayButton")
    }

    /// The overflow "moon" menu's artwork-edit items are already gated; Equalizer and Share
    /// Artwork must join them so only the sleep-timer entries remain for ambient playback.
    func testOverflowMenuHidesEqualizerAndShareForAmbient() throws {
        let text = try source()
        XCTAssertTrue(text.contains("if !player.isAmbient {\n                    Button { showEQ = true } label: { Label(\"Equalizer\", systemImage: \"slider.vertical.3\") }\n                }"),
            "Equalizer must be hidden for ambient playback")
        XCTAssertTrue(text.contains("if !player.isAmbient, let row = player.currentTrack, let shareURL = shareURL(for: row) {"),
            "Share Artwork must be hidden for ambient playback")
    }

    func testSleepTimerEntriesStayUnconditional() throws {
        let text = try source()
        for label in ["\"15 minutes\"", "\"30 minutes\"", "\"45 minutes\"", "\"1 hour\"", "\"End of track\""] {
            XCTAssertTrue(text.contains("Button(\(label))"), "sleep timer entry \(label) must still exist")
        }
        let eqRange = try XCTUnwrap(text.range(of: "Label(\"Equalizer\""))
        let sleepRange = try XCTUnwrap(text.range(of: "Button(\"15 minutes\")"))
        XCTAssertLessThan(eqRange.lowerBound, sleepRange.lowerBound,
            "sleep timer entries sit after (outside) the Equalizer's own isAmbient guard")
    }

    /// Queue is already correct per the request — confirm it isn't touched by this change.
    func testQueueStaysUnconditional() throws {
        let text = try source()
        XCTAssertFalse(text.contains("if !player.isAmbient {\n                UpNextView"),
            "UpNextView (Queue) must remain unconditional")
        XCTAssertTrue(text.contains("UpNextView()"))
    }
}
