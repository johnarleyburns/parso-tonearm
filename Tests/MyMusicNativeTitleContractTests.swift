#if !os(watchOS)
import XCTest

/// My Music uses the native large navigation title; an embedded PlaylistsView must not hide the parent bar.
final class MyMusicNativeTitleContractTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    func testMyMusicUsesNativeLargeTitleAndKeepsNavigationPath() throws {
        let s = try source("Sources/Features/MyMusic/MyMusicView.swift")
        XCTAssertFalse(s.contains("ScreenHeader("), "custom My Music header must be gone")
        XCTAssertFalse(s.contains("hiddenNavigationBar"), "My Music root must not hide its bar")
        XCTAssertTrue(s.contains(".navigationTitle(\"My Music\")"))
        XCTAssertTrue(s.contains(".largeNavigationTitle()"))
        XCTAssertTrue(s.contains("NavigationStack(path: $navigationPath)"))
        XCTAssertTrue(s.contains("consumePendingArtistFilter"))
    }

    func testEmbeddedPlaylistsViewDoesNotHideParentBar() throws {
        let s = try source("Sources/Features/Playlists/PlaylistsView.swift")
        XCTAssertFalse(s.contains(".hiddenNavigationBar()"))
        XCTAssertTrue(s.contains(".hiddenNavigationBar(when: ownsNavigationStack)"))
    }
}
#endif
