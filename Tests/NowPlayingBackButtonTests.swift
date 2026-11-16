import XCTest

/// Real report: Now Playing showed both a "<" back button and the zoom transition's own
/// swipe-down-to-collapse-into-the-mini-player gesture — two ways to dismiss the same screen.
/// Only the swipe gesture is wanted; the back button must stay hidden regardless.
final class NowPlayingBackButtonTests: XCTestCase {
    func testBackButtonIsHiddenSoOnlySwipeToCollapseRemains() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Features/NowPlaying/NowPlayingView.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains(".navigationBarBackButtonHidden(true)"))
    }
}
