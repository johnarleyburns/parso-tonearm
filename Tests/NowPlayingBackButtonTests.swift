import Foundation
import Testing

/// Real report: Now Playing showed both a "<" back button and the zoom transition's own
/// swipe-down-to-collapse-into-the-mini-player gesture — two ways to dismiss the same screen.
/// The nav-bar back button stays hidden; "Back" now lives as an explicit item in the
/// top-right actions menu.
@Suite struct NowPlayingBackButtonTests {
    @Test func testNavBarBackButtonStaysHiddenAndBackLivesInActionsMenu() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Features/NowPlaying/NowPlayingView.swift"),
            encoding: .utf8)
        #expect(source.contains(".navigationBarBackButtonHidden(true)"))
        #expect(source.contains("\"np.back\""))
    }
}
