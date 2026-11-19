import XCTest

/// Real report: Ambient's Now Playing should be highly simplified — only play/pause, AirPlay,
/// and the sleep timer, with everything else hidden (Queue stays, already correct). The secondary
/// actions now live in one top-right glass actions menu; ambient must still show only AirPlay and
/// the sleep submenu from that menu. Source inspection (no simulator), matching this repo's
/// established convention.
final class NowPlayingAmbientSimplificationTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/NowPlaying/NowPlayingView.swift"),
            encoding: .utf8)
    }

    private func actionsMenuBlock(_ text: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: "private var actionsMenu: some View"))
        let end = try XCTUnwrap(text.range(of: "private var airPlayPickerSheet",
                                            range: start.upperBound..<text.endIndex))
        return text[start.lowerBound..<end.lowerBound]
    }

    func testActionsMenuLivesInTheRightToolbarNotTheBody() throws {
        let text = try source()
        XCTAssertTrue(text.contains(".toolbar {\n            ToolbarItem(placement: .topBarTrailing) {\n                actionsMenu"),
                      "the actions must sit in a right-side toolbar item")
        XCTAssertFalse(text.contains("toolbar.padding(.top, 16)"),
                       "the old inline action row must be gone")
    }

    func testActionsMenuContainsEveryRequestedAction() throws {
        let block = try actionsMenuBlock(try source())
        for identifier in [
            "np.back", "np.repeat", "np.shuffle", "np.favorite", "np.addToPlaylist",
            "np.airplay", "np.download", "np.watchDownload", "np.sleep"
        ] {
            XCTAssertTrue(block.contains("\"\(identifier)\""), "missing \(identifier) in the actions menu")
        }
        XCTAssertTrue(block.contains("Label(\"AirPlay\", systemImage: \"airplayaudio\")"))
    }

    /// The track-only actions sit inside `if !player.isAmbient` guards; AirPlay and
    /// the sleep submenu do not.
    func testAmbientHidesTrackActionsButKeepsAirPlayAndSleep() throws {
        let block = try actionsMenuBlock(try source())
        let firstGuard = try XCTUnwrap(block.range(of: "if !player.isAmbient {"))
        let firstGuardClose = try XCTUnwrap(block.range(
            of: "\n            }\n\n            Button { showAirPlayPicker = true }",
            range: firstGuard.upperBound..<block.endIndex))
        let firstGuarded = block[firstGuard.lowerBound..<firstGuardClose.lowerBound]
        for identifier in ["np.repeat", "np.shuffle", "np.favorite", "np.addToPlaylist"] {
            XCTAssertTrue(firstGuarded.contains("\"\(identifier)\""),
                          "\(identifier) must be hidden for ambient playback")
        }

        let secondGuard = try XCTUnwrap(block.range(
            of: "if !player.isAmbient {",
            range: firstGuardClose.upperBound..<block.endIndex))
        let secondGuardClose = try XCTUnwrap(block.range(
            of: "\n            }\n\n            Menu {",
            range: secondGuard.upperBound..<block.endIndex))
        let secondGuarded = block[secondGuard.lowerBound..<secondGuardClose.lowerBound]
        for identifier in ["np.download", "np.watchDownload"] {
            XCTAssertTrue(secondGuarded.contains("\"\(identifier)\""),
                          "\(identifier) must be hidden for ambient playback")
        }

        let unconditional = block[firstGuardClose.lowerBound..<secondGuard.lowerBound]
        XCTAssertTrue(unconditional.contains("\"np.airplay\""),
                      "AirPlay must remain available for ambient playback")
        XCTAssertTrue(block.contains("Label(sleepTitle, systemImage: sleepIcon)"),
                      "sleep timer must remain available for ambient playback")
    }

    func testTransportKeepsOnlyPlayPauseUnconditional() throws {
        let text = try source()
        let prevRange = try XCTUnwrap(text.range(of: "\"np.prev\""))
        let playPause = try XCTUnwrap(text.range(of: "\"np.playpause\""))
        let nextRange = try XCTUnwrap(text.range(of: "\"np.next\""))
        XCTAssertLessThan(prevRange.lowerBound, playPause.lowerBound)
        XCTAssertLessThan(playPause.lowerBound, nextRange.lowerBound)

        // prev is inside a leading `if !player.isAmbient` guard that closes
        // immediately before play/pause; next is inside a trailing guard.
        let prevGuardClose = try XCTUnwrap(text.range(
            of: "\n            }\n            Button { player.togglePlayPause()",
            range: prevRange.upperBound..<playPause.lowerBound))
        XCTAssertLessThan(prevRange.lowerBound, prevGuardClose.lowerBound)
        let nextGuard = try XCTUnwrap(text.range(
            of: "if !player.isAmbient {", options: .backwards,
            range: playPause.upperBound..<nextRange.lowerBound))
        XCTAssertLessThan(nextGuard.lowerBound, nextRange.lowerBound,
                          "next must be hidden for ambient playback")
    }

    func testSleepTimerEntriesStay() throws {
        let text = try source()
        for label in ["\"15 minutes\"", "\"30 minutes\"", "\"45 minutes\"", "\"1 hour\"", "\"End of track\""] {
            XCTAssertTrue(text.contains("Button(\(label))"), "sleep timer entry \(label) must still exist")
        }
    }

    func testQueueStaysUnconditional() throws {
        let text = try source()
        XCTAssertFalse(text.contains("if !player.isAmbient {\n                UpNextView"),
                       "UpNextView (Queue) must remain unconditional")
        XCTAssertTrue(text.contains("UpNextView()"))
    }
}
