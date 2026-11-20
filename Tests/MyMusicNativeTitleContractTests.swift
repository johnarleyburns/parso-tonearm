#if !os(watchOS)
import Foundation
import Testing

/// My Music uses the native large navigation title; an embedded PlaylistsView must not hide the parent bar.
@Suite struct MyMusicNativeTitleContractTests {
    private func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func testMyMusicUsesNativeLargeTitleAndKeepsNavigationPath() throws {
        let s = try source("Sources/Features/MyMusic/MyMusicView.swift")
        #expect(!s.contains("ScreenHeader("), "custom My Music header must be gone")
        #expect(!s.contains("hiddenNavigationBar"), "My Music root must not hide its bar")
        #expect(s.contains(".navigationTitle(\"My Music\")"))
        #expect(s.contains(".largeNavigationTitle()"))
        #expect(s.contains("NavigationStack(path: $navigationPath)"))
        #expect(s.contains("consumePendingArtistFilter"))
    }

    @Test func testEmbeddedPlaylistsViewDoesNotHideParentBar() throws {
        let s = try source("Sources/Features/Playlists/PlaylistsView.swift")
        #expect(!s.contains(".hiddenNavigationBar()"))
        #expect(s.contains(".hiddenNavigationBar(when: ownsNavigationStack)"))
    }
}
#endif
