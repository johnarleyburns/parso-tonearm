import XCTest

/// Real reports: (1) My Music > Playlists showed a redundant "Your Playlists" caption row and a
/// "Playlists +" header row — the "+" moves to a top-left glass toolbar button instead; (2) My
/// Music's top-right toolbar should group a Libraries icon (pushing the current Libraries screen)
/// next to the existing Sound Index icon, and the standalone Libraries tab goes away (3 tabs:
/// Listen, My Music, Find). Source inspection (no simulator), matching this repo's established
/// convention — see `Tests/RootTabNavigationContractTests.swift`.
final class MyMusicToolbarTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testPlaylistsViewHasNoInlineHeaderOrCaption() throws {
        let playlists = try source("Sources/Features/Playlists/PlaylistsView.swift")
        XCTAssertFalse(playlists.contains("Your Playlists"),
            "the redundant 'Your Playlists' caption row must be removed")
        XCTAssertFalse(playlists.contains("ScreenHeader"),
            "the 'Playlists +' header row moves to MyMusicView's own toolbar")
        XCTAssertFalse(playlists.contains("presentsCreateSheetLocally"),
            "dead now that no caller needs a locally-presented create sheet")
    }

    func testMyMusicHasTopLeftCreatePlaylistButtonScopedToPlaylists() throws {
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        XCTAssertTrue(myMusic.contains("if scope == .playlists {"))
        let scopeGuardRange = try XCTUnwrap(myMusic.range(of: "if scope == .playlists {"))
        let topLeadingRange = try XCTUnwrap(myMusic.range(of: "ToolbarItem(placement: .topBarLeading)",
                                                            range: scopeGuardRange.lowerBound..<myMusic.endIndex))
        XCTAssertLessThan(scopeGuardRange.lowerBound, topLeadingRange.lowerBound)
        XCTAssertTrue(myMusic.contains("\"playlists.create\""),
            "reuses the same identifier the old inline header row had")
        XCTAssertFalse(myMusic.contains(".padding(.horizontal, 18)"),
            "contract: MyMusicView must keep the 16pt gutter, not reintroduce an 18pt one")
    }

    func testMyMusicToolbarGroupsLibraryAndSoundIndexIcons() throws {
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        let groupRange = try XCTUnwrap(myMusic.range(of: "ToolbarItemGroup(placement: .primaryAction)"))
        let libraryRange = try XCTUnwrap(myMusic.range(of: "\"mymusic.libraries\""))
        let indexRange = try XCTUnwrap(myMusic.range(of: "\"mymusic.indexStatus\""))
        XCTAssertLessThan(groupRange.lowerBound, libraryRange.lowerBound,
            "the library icon must sit inside the grouped toolbar")
        XCTAssertLessThan(libraryRange.lowerBound, indexRange.lowerBound,
            "library icon must come before the sound-index icon, per the requested order")
        XCTAssertTrue(myMusic.contains("showLibraries = true"),
            "the library icon must open Libraries from a button-driven sheet")
        XCTAssertTrue(myMusic.contains("SourcesView(ownsNavigationStack: true, showsDoneButton: true)"),
            "Libraries must be presented as a dismissable sheet with its own stack and Done affordance")
        XCTAssertTrue(myMusic.contains(".sheet(isPresented: $showLibraries)"),
            "Libraries is a sheet, not a pushed page (real report: no way to dismiss it)")
    }

    /// Real reports: (1) Libraries opened as a pushed page with no dismiss
    /// affordance; (2) tapping an already-configured library flashed
    /// `SourceDetailView` then popped straight back to the Libraries list.
    func testLibrariesSheetHasDoneButtonAndRowsPushDetailDirectly() throws {
        let sources = try source("Sources/Features/Sources/SourcesView.swift")
        XCTAssertTrue(sources.contains("showsDoneButton: Bool = false"))
        XCTAssertTrue(sources.contains("doneAction: showsDoneButton ? { dismiss() } : nil"),
            "the sheet-presented Libraries screen needs its own Done button — its nav bar is hidden")
        XCTAssertFalse(sources.contains("NavigationLink(value: source)"),
            "configured-library rows must push SourceDetailView with a destination closure; the "
                + "value-based link flashed and returned when the destination registration was missing")
        XCTAssertTrue(sources.contains("NavigationLink {\n                                SourceDetailView(source: source)"),
            "local library rows open SourceDetailView directly")

        let components = try source("Sources/Features/Components.swift")
        XCTAssertTrue(components.contains("var doneAction: (() -> Void)? = nil"))
        XCTAssertTrue(components.contains("Button(\"Done\", action: doneAction)"))
    }

    func testRootViewHasExactlyThreeTabs() throws {
        let root = try source("Sources/Features/RootView.swift")
        XCTAssertFalse(root.contains("SourcesView()"), "the standalone Libraries tab must be removed")
        XCTAssertFalse(root.contains(".tag(AppTab.libraries)"))
        for tag in ["AppTab.listen", "AppTab.myMusic", "AppTab.find"] {
            XCTAssertTrue(root.contains(".tag(\(tag))"), "\(tag) tab must remain")
        }
        let tabItemCount = root.components(separatedBy: ".tabItem {").count - 1
        XCTAssertEqual(tabItemCount, 3, "exactly 3 tabs: Listen, My Music, Find")
    }

    /// `AppTab.libraries` stays in the enum (never reused/renumbered, same convention as the
    /// earlier `mood` case) purely so `SourcesView`'s internal `.rootTabChrome(.libraries, ...)`
    /// call keeps compiling — it's harmless once no tab can ever select it.
    func testAppTabLibrariesCaseIsKeptForInternalChromeOnly() throws {
        let appState = try source("Sources/App/AppState.swift")
        XCTAssertTrue(appState.contains("libraries = 4"))
    }

    func testPersistedLibrariesTabSelectionFallsBackToMyMusic() throws {
        let appState = try source("Sources/App/AppState.swift")
        XCTAssertTrue(appState.contains(".libraries"))
        XCTAssertTrue(appState.contains(".myMusic"))
        // The restore path must special-case a persisted `.libraries` selection, same convention
        // already used for the removed `mood` tab.
        XCTAssertTrue(appState.contains("restored == .libraries") || appState.contains("== .libraries ? .myMusic"),
            "restoring a persisted Libraries tab selection must fall back to My Music")
    }
}
