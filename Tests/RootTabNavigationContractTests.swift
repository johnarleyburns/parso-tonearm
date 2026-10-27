import Foundation
import XCTest

/// Source contract: each root tab owns exactly one NavigationStack, with a
/// native large title, and the Now Playing destination lives inside it.
final class RootTabNavigationContractTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testRootViewHasNoGlobalStackAroundTabView() throws {
        let root = try source("Sources/Features/RootView.swift")
        let rootTabs = try XCTUnwrap(root.range(of: "private var rootTabs"))
        let body = String(root[..<rootTabs.lowerBound])
        XCTAssertFalse(body.contains("NavigationStack"), "RootView body must not wrap rootTabs in a NavigationStack")
        XCTAssertFalse(body.contains("navigationDestination"))
        let tabs = try XCTUnwrap(root.range(of: "TabView(selection"))
        let beforeTabView = root[..<tabs.lowerBound].suffix(80)
        XCTAssertFalse(beforeTabView.contains("NavigationStack {"))
    }

    func testListenAndMoodAreHostedByLocalStacks() throws {
        let root = try source("Sources/Features/RootView.swift")
        XCTAssertEqual(count("NavigationStack {", in: root), 2)
        let squashed = root.components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertTrue(squashed.contains("NavigationStack{ListenView().rootTabChrome(.listen)}"))
        XCTAssertTrue(squashed.contains("NavigationStack{MoodView().rootTabChrome(.mood)}"))
        XCTAssertFalse(root.contains("NavigationStack {\n                MyMusicView"))
    }

    func testMyMusicAndFindOwnExactlyOneStackEach() throws {
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        let find = try source("Sources/Features/Find/FindView.swift")
        XCTAssertEqual(count("\n        NavigationStack", in: myMusic), 1)
        XCTAssertEqual(count("\n        NavigationStack", in: find), 1)
        XCTAssertTrue(myMusic.contains("NavigationStack(path: $navigationPath)"))
        XCTAssertTrue(myMusic.contains(".rootTabChrome(.myMusic)"))
        XCTAssertTrue(find.contains(".rootTabChrome(.find)"))
    }

    func testRootViewsDeclareNativeLargeTitles() throws {
        let listen = try source("Sources/Features/Listen/ListenView.swift")
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        let find = try source("Sources/Features/Find/FindView.swift")
        for (text, title) in [(listen, "Listen"), (listen, "Mood"), (myMusic, "My Music"), (find, "Find")] {
            let squashed = text.components(separatedBy: .whitespacesAndNewlines).joined()
            let key = ".navigationTitle(\"\(title)\").largeNavigationTitle()".replacingOccurrences(of: " ", with: "")
            XCTAssertTrue(squashed.contains(key), "\(title) needs navigationTitle + large display mode")
        }
        XCTAssertFalse(listen.contains("nativeLargeTitle"), "no divergent large-title helper")
        let compat = try source("Sources/DesignSystem/PlatformCompat.swift")
        XCTAssertTrue(compat.contains("navigationBarTitleDisplayMode(.large)"))
    }

    func testRootPathsNeverHideNavigationBar() throws {
        for path in ["Sources/Features/RootView.swift", "Sources/Features/RootTabChrome.swift",
                     "Sources/Features/Listen/ListenView.swift", "Sources/Features/MyMusic/MyMusicView.swift",
                     "Sources/Features/Find/FindView.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains("hiddenNavigationBar"), path)
            XCTAssertFalse(text.contains(".navigationBarHidden"), path)
            XCTAssertFalse(text.contains(".toolbar(.hidden, for: .navigationBar)"), path)
            XCTAssertFalse(text.contains("ScreenHeader"), path)
        }
    }

    func testSharedNowPlayingDestinationKeepsZoomAndIsTabScoped() throws {
        let chrome = try source("Sources/Features/RootTabChrome.swift")
        XCTAssertTrue(chrome.contains(".navigationDestination(isPresented: nowPlaying)"))
        XCTAssertTrue(chrome.contains(".navigationTransition(.zoom(sourceID: \"now-playing\""))
        XCTAssertTrue(chrome.contains("appState.showNowPlaying && appState.tab == tab"))
        XCTAssertTrue(chrome.contains(".safeAreaInset(edge: .bottom"))
        let root = try source("Sources/Features/RootView.swift")
        XCTAssertEqual(count(".rootTabChrome(", in: root), 2)
        XCTAssertTrue(root.contains("rootTabNowPlayingNamespace, nowPlayingTransition"))
    }

    func testRootContentUsesSixteenPointGutter() throws {
        let listen = try source("Sources/Features/Listen/ListenView.swift")
        XCTAssertEqual(count(".padding(.horizontal, 18)", in: listen), 0)
        XCTAssertGreaterThanOrEqual(count(".padding(.horizontal, 16)", in: listen), 2)
        XCTAssertFalse(try source("Sources/Features/MyMusic/MyMusicView.swift").contains(".padding(.horizontal, 18)"))
        XCTAssertFalse(try source("Sources/Features/Find/FindView.swift").contains(".padding(.horizontal, 18)"))
    }
}
