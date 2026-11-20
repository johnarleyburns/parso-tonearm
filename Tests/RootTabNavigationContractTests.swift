import Foundation
import Testing

/// Source contract: each root tab owns exactly one NavigationStack, with a
/// native large title, and the Now Playing destination lives inside it.
@Suite struct RootTabNavigationContractTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func testRootViewHasNoGlobalStackAroundTabView() throws {
        let root = try source("Sources/Features/RootView.swift")
        let rootTabs = try #require(root.range(of: "private var rootTabs"))
        let body = String(root[..<rootTabs.lowerBound])
        #expect(!body.contains("NavigationStack"), "RootView body must not wrap rootTabs in a NavigationStack")
        #expect(!body.contains("navigationDestination"))
        let tabs = try #require(root.range(of: "TabView(selection"))
        let beforeTabView = root[..<tabs.lowerBound].suffix(80)
        #expect(!beforeTabView.contains("NavigationStack {"))
    }

    @Test func testListenIsHostedByALocalStack() throws {
        let root = try source("Sources/Features/RootView.swift")
        #expect(count("NavigationStack {", in: root) == 1)
        let squashed = root.components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(squashed.contains("NavigationStack{ListenView().rootTabChrome(.listen)}"))
        #expect(!root.contains("NavigationStack {\n                MyMusicView"))
    }

    @Test func testMyMusicAndFindOwnExactlyOneStackEach() throws {
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        let find = try source("Sources/Features/Find/FindView.swift")
        #expect(count("\n        NavigationStack", in: myMusic) == 1)
        #expect(count("\n        NavigationStack", in: find) == 1)
        #expect(myMusic.contains("NavigationStack(path: $navigationPath)"))
        #expect(myMusic.contains(".rootTabChrome(.myMusic)"))
        #expect(find.contains(".rootTabChrome(.find)"))
    }

    @Test func testRootViewsDeclareNativeLargeTitles() throws {
        let listen = try source("Sources/Features/Listen/ListenView.swift")
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        let find = try source("Sources/Features/Find/FindView.swift")
        for (text, title) in [(listen, "Listen"), (myMusic, "My Music"), (find, "Find")] {
            let squashed = text.components(separatedBy: .whitespacesAndNewlines).joined()
            let key = ".navigationTitle(\"\(title)\").largeNavigationTitle()".replacingOccurrences(of: " ", with: "")
            #expect(squashed.contains(key), "\(title) needs navigationTitle + large display mode")
        }
        #expect(!listen.contains("nativeLargeTitle"), "no divergent large-title helper")
        let compat = try source("Sources/DesignSystem/PlatformCompat.swift")
        #expect(compat.contains("navigationBarTitleDisplayMode(.large)"))
    }

    @Test func testRootPathsNeverHideNavigationBar() throws {
        for path in ["Sources/Features/RootView.swift", "Sources/Features/RootTabChrome.swift",
                     "Sources/Features/Listen/ListenView.swift", "Sources/Features/MyMusic/MyMusicView.swift",
                     "Sources/Features/Find/FindView.swift"] {
            let text = try source(path)
            // Find may hide its bar only conditionally (while the search field is focused).
            if path.hasSuffix("Find/FindView.swift") {
                #expect(!text.contains(".hiddenNavigationBar()"), "\(path)")
                #expect(text.contains(".hiddenNavigationBar(when: queryFocused"), "\(path)")
            } else {
                #expect(!text.contains("hiddenNavigationBar"), "\(path)")
            }
            #expect(!text.contains(".navigationBarHidden"), "\(path)")
            #expect(!text.contains(".toolbar(.hidden, for: .navigationBar)"), "\(path)")
            #expect(!text.contains("ScreenHeader"), "\(path)")
        }
    }

    @Test func testSharedNowPlayingDestinationKeepsZoomAndIsTabScoped() throws {
        let chrome = try source("Sources/Features/RootTabChrome.swift")
        // item:, not isPresented: — the same boolean-driven-presentation fragility
        // SettingsView.swift already diagnosed and fixed once for a sheet.
        #expect(chrome.contains(".navigationDestination(item: nowPlayingItem)"))
        // Tabs with an explicit NavigationPath (Libraries) push Now Playing onto that same path,
        // so "<" pops one entry instead of collapsing the stack to the tab root.
        #expect(chrome.contains(".navigationDestination(for: NowPlayingRoute.self)"))
        #expect(chrome.contains("path.wrappedValue.append(NowPlayingRoute())"))
        let sources = try source("Sources/Features/Sources/SourcesView.swift")
        #expect(sources.contains(".rootTabChrome(.libraries, path: ownsNavigationStack ? $navigationPath : nil)"))
        #expect(chrome.contains(".navigationTransition(.zoom(sourceID: \"now-playing\""))
        #expect(chrome.contains("appState.showNowPlaying && appState.tab == tab"))
        #expect(chrome.contains(".safeAreaInset(edge: .bottom"))
        let root = try source("Sources/Features/RootView.swift")
        #expect(count(".rootTabChrome(", in: root) == 1)
        #expect(root.contains("rootTabNowPlayingNamespace, nowPlayingTransition"))
    }

    @Test func testRootContentUsesSixteenPointGutter() throws {
        let listen = try source("Sources/Features/Listen/ListenView.swift")
        #expect(count(".padding(.horizontal, 18)", in: listen) == 0)
        #expect(count(".padding(.horizontal, 16)", in: listen) >= 1)
        #expect(!(try source("Sources/Features/MyMusic/MyMusicView.swift").contains(".padding(.horizontal, 18)")))
        #expect(!(try source("Sources/Features/Find/FindView.swift").contains(".padding(.horizontal, 18)")))
    }
}
