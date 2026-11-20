import Foundation
import Testing

/// Real reports: (1) My Music > Playlists showed a redundant "Your Playlists" caption row and a
/// "Playlists +" header row — the "+" moves to a top-left glass toolbar button instead; (2) My
/// Music's top-right toolbar should group a Libraries icon (pushing the current Libraries screen)
/// next to the existing Sound Index icon, and the standalone Libraries tab goes away (3 tabs:
/// Listen, My Music, Find). Source inspection (no simulator), matching this repo's established
/// convention — see `Tests/RootTabNavigationContractTests.swift`.
@Suite struct MyMusicToolbarTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func testPlaylistsViewHasNoInlineHeaderOrCaption() throws {
        let playlists = try source("Sources/Features/Playlists/PlaylistsView.swift")
        #expect(!playlists.contains("Your Playlists"),
            "the redundant 'Your Playlists' caption row must be removed")
        #expect(!playlists.contains("ScreenHeader"),
            "the 'Playlists +' header row moves to MyMusicView's own toolbar")
        #expect(!playlists.contains("presentsCreateSheetLocally"),
            "dead now that no caller needs a locally-presented create sheet")
    }

    @Test func testMyMusicHasTopLeftCreatePlaylistButtonScopedToPlaylists() throws {
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        #expect(myMusic.contains("if scope == .playlists {"))
        let scopeGuardRange = try #require(myMusic.range(of: "if scope == .playlists {"))
        let topLeadingRange = try #require(myMusic.range(of: "ToolbarItem(placement: .topBarLeading)",
                                                           range: scopeGuardRange.lowerBound..<myMusic.endIndex))
        #expect(scopeGuardRange.lowerBound < topLeadingRange.lowerBound)
        #expect(myMusic.contains("\"playlists.create\""),
            "reuses the same identifier the old inline header row had")
        #expect(!myMusic.contains(".padding(.horizontal, 18)"),
            "contract: MyMusicView must keep the 16pt gutter, not reintroduce an 18pt one")
    }

    @Test func testMyMusicToolbarGroupsLibraryAndSoundIndexIcons() throws {
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        let groupRange = try #require(myMusic.range(of: "ToolbarItemGroup(placement: .primaryAction)"))
        let libraryRange = try #require(myMusic.range(of: "\"mymusic.libraries\""))
        let indexRange = try #require(myMusic.range(of: "\"mymusic.indexStatus\""))
        #expect(groupRange.lowerBound < libraryRange.lowerBound,
            "the library icon must sit inside the grouped toolbar")
        #expect(libraryRange.lowerBound < indexRange.lowerBound,
            "library icon must come before the sound-index icon, per the requested order")
        #expect(myMusic.contains("SourcesView(ownsNavigationStack: false, showsBackButton: true)"),
            "the library icon must push the same Libraries screen, with its own header back button")
        #expect(!myMusic.contains(".sheet(isPresented: $showLibraries)"),
            "Libraries is navigation with a back affordance, not a sheet")
    }

    /// Real reports: (1) Libraries opened as a pushed page with no way back
    /// because its navigation bar is hidden; (2) tapping an already-configured
    /// library flashed `SourceDetailView` then popped straight back.
    @Test func testLibrariesPushUsesHeaderBackAndRowsPushDetailDirectly() throws {
        let sources = try source("Sources/Features/Sources/SourcesView.swift")
        #expect(sources.contains("showsBackButton: Bool = false"))
        #expect(sources.contains("backAction: showsBackButton ? { dismiss() } : nil"),
            "the pushed Libraries screen needs its own header back button — its nav bar is hidden")
        #expect(!sources.contains("NavigationLink(value: source)"),
            "configured-library rows must push SourceDetailView with a destination closure; the "
                + "value-based link flashed and returned when the destination registration was missing")
        #expect(sources.contains("NavigationLink {\n                                SourceDetailView(source: source)"),
            "local library rows open SourceDetailView directly")

        let components = try source("Sources/Features/Components.swift")
        #expect(components.contains("var backAction: (() -> Void)? = nil"))
        #expect(components.contains("Image(systemName: \"chevron.left\")"))
        #expect(components.contains("\"screen.back\""))
    }

    @Test func testRootViewHasExactlyThreeTabs() throws {
        let root = try source("Sources/Features/RootView.swift")
        #expect(!root.contains("SourcesView()"), "the standalone Libraries tab must be removed")
        #expect(!root.contains(".tag(AppTab.libraries)"))
        for tag in ["AppTab.listen", "AppTab.myMusic", "AppTab.find"] {
            #expect(root.contains(".tag(\(tag))"), "\(tag) tab must remain")
        }
        let tabItemCount = root.components(separatedBy: ".tabItem {").count - 1
        #expect(tabItemCount == 3, "exactly 3 tabs: Listen, My Music, Find")
    }

    /// `AppTab.libraries` stays in the enum (never reused/renumbered, same convention as the
    /// earlier `mood` case) purely so `SourcesView`'s internal `.rootTabChrome(.libraries, ...)`
    /// call keeps compiling — it's harmless once no tab can ever select it.
    @Test func testAppTabLibrariesCaseIsKeptForInternalChromeOnly() throws {
        let appState = try source("Sources/App/AppState.swift")
        #expect(appState.contains("libraries = 4"))
    }

    @Test func testPersistedLibrariesTabSelectionFallsBackToMyMusic() throws {
        let appState = try source("Sources/App/AppState.swift")
        #expect(appState.contains(".libraries"))
        #expect(appState.contains(".myMusic"))
        // The restore path must special-case a persisted `.libraries` selection, same convention
        // already used for the removed `mood` tab.
        #expect(appState.contains("restored == .libraries") || appState.contains("== .libraries ? .myMusic"),
            "restoring a persisted Libraries tab selection must fall back to My Music")
    }
}
