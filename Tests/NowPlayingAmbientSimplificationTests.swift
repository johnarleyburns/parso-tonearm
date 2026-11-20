import Foundation
import Testing

/// Real report: Ambient's Now Playing should be highly simplified — only play/pause, AirPlay,
/// and the sleep timer, with everything else hidden (Queue stays, already correct). The secondary
/// actions now live in one top-right glass actions menu; ambient must still show only AirPlay and
/// the sleep submenu from that menu. Source inspection (no simulator), matching this repo's
/// established convention.
@Suite struct NowPlayingAmbientSimplificationTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/NowPlaying/NowPlayingView.swift"),
            encoding: .utf8)
    }

    private func actionsMenuBlock(_ text: String) throws -> Substring {
        let start = try #require(text.range(of: "private var actionsMenu: some View"))
        let end = try #require(text.range(of: "private var airPlayPickerSheet",
                                            range: start.upperBound..<text.endIndex))
        return text[start.lowerBound..<end.lowerBound]
    }

    @Test func testActionsMenuLivesInTheRightToolbarNotTheBody() throws {
        let text = try source()
        #expect(text.contains(".toolbar {\n            ToolbarItem(placement: .topBarTrailing) {\n                actionsMenu"),
                "the actions must sit in a right-side toolbar item")
        #expect(!text.contains("toolbar.padding(.top, 16)"),
                "the old inline action row must be gone")
    }

    @Test func testActionsMenuContainsEveryRequestedAction() throws {
        let block = try actionsMenuBlock(try source())
        for identifier in [
            "np.back", "np.repeat", "np.shuffle", "np.favorite", "np.addToPlaylist",
            "np.airplay", "np.download", "np.watchDownload", "np.sleep"
        ] {
            #expect(block.contains("\"\(identifier)\""), "missing \(identifier) in the actions menu")
        }
        #expect(block.contains("Label(\"AirPlay\", systemImage: \"airplayaudio\")"))
    }

    /// The track-only actions sit inside `if !player.isAmbient` guards; AirPlay and
    /// the sleep submenu do not.
    @Test func testAmbientHidesTrackActionsButKeepsAirPlayAndSleep() throws {
        let block = try actionsMenuBlock(try source())
        let firstGuard = try #require(block.range(of: "if !player.isAmbient {"))
        let firstGuardClose = try #require(block.range(
            of: "\n            }\n\n            Button { showAirPlayPicker = true }",
            range: firstGuard.upperBound..<block.endIndex))
        let firstGuarded = block[firstGuard.lowerBound..<firstGuardClose.lowerBound]
        for identifier in ["np.repeat", "np.shuffle", "np.favorite", "np.addToPlaylist"] {
            #expect(firstGuarded.contains("\"\(identifier)\""),
                    "\(identifier) must be hidden for ambient playback")
        }

        let secondGuard = try #require(block.range(
            of: "if !player.isAmbient {",
            range: firstGuardClose.upperBound..<block.endIndex))
        let secondGuardClose = try #require(block.range(
            of: "\n            }\n\n            Menu {",
            range: secondGuard.upperBound..<block.endIndex))
        let secondGuarded = block[secondGuard.lowerBound..<secondGuardClose.lowerBound]
        for identifier in ["np.download", "np.watchDownload"] {
            #expect(secondGuarded.contains("\"\(identifier)\""),
                    "\(identifier) must be hidden for ambient playback")
        }

        let unconditional = block[firstGuardClose.lowerBound..<secondGuard.lowerBound]
        #expect(unconditional.contains("\"np.airplay\""),
                "AirPlay must remain available for ambient playback")
        #expect(block.contains("Label(sleepTitle, systemImage: sleepIcon)"),
                "sleep timer must remain available for ambient playback")
    }

    @Test func testTransportKeepsOnlyPlayPauseUnconditional() throws {
        let text = try source()
        let prevRange = try #require(text.range(of: "\"np.prev\""))
        let playPause = try #require(text.range(of: "\"np.playpause\""))
        let nextRange = try #require(text.range(of: "\"np.next\""))
        #expect(prevRange.lowerBound < playPause.lowerBound)
        #expect(playPause.lowerBound < nextRange.lowerBound)

        // prev is inside a leading `if !player.isAmbient` guard that closes
        // immediately before play/pause; next is inside a trailing guard.
        let prevGuardClose = try #require(text.range(
            of: "\n            }\n            Button { player.togglePlayPause()",
            range: prevRange.upperBound..<playPause.lowerBound))
        #expect(prevRange.lowerBound < prevGuardClose.lowerBound)
        let nextGuard = try #require(text.range(
            of: "if !player.isAmbient {", options: .backwards,
            range: playPause.upperBound..<nextRange.lowerBound))
        #expect(nextGuard.lowerBound < nextRange.lowerBound,
                "next must be hidden for ambient playback")
    }

    @Test func testSleepTimerEntriesStay() throws {
        let text = try source()
        for label in ["\"15 minutes\"", "\"30 minutes\"", "\"45 minutes\"", "\"1 hour\"", "\"End of track\""] {
            #expect(text.contains("Button(\(label))"), "sleep timer entry \(label) must still exist")
        }
    }

    @Test func testQueueStaysUnconditional() throws {
        let text = try source()
        #expect(!text.contains("if !player.isAmbient {\n                UpNextView"),
                "UpNextView (Queue) must remain unconditional")
        #expect(text.contains("UpNextView()"))
    }
}
