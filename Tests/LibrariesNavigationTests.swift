import Foundation
import Testing

/// Real report: tapping an already-configured remote provider showed its
/// library list for an instant and immediately popped back. Same SwiftUI
/// failure PR #453 fixed for source rows: a value-based `NavigationLink`
/// inside this pushed screen depends on a `navigationDestination` registered
/// in that same pushed child, which the parent stack does not see, so the tap
/// flashes and pops. Every row in `SourcesView` must push with a destination
/// closure. Source inspection (no simulator), matching this repo's convention.
@Suite struct LibrariesNavigationTests {
    private func sourcesView() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Sources/SourcesView.swift"),
            encoding: .utf8)
    }

    @Test func testNoValueBasedNavigationLinksRemain() throws {
        let text = try sourcesView()
        // Space after the colon so the explanatory comments mentioning the old
        // `NavigationLink(value:)` form do not match.
        #expect(!text.contains("NavigationLink(value: "),
            "pushed Libraries rows must use a destination closure; value links flash and pop")
        #expect(!text.contains(".navigationDestination(for: ProviderInstancesTarget.self)"),
            "a destination registered inside the pushed child is invisible to the parent stack")
        #expect(!text.contains(".navigationDestination(for: LibraryService.self)"),
            "Jamendo must push with a destination closure like every other row")
    }

    @Test func testConfiguredRemoteProviderPushesItsInstanceList() throws {
        let text = try sourcesView()
        #expect(text.contains("ProviderInstancesView(connector: connector, navigationPath: $navigationPath)"),
            "the enabled provider row must push ProviderInstancesView directly")
        #expect(text.contains("JamendoBrowseView()"),
            "the enabled Jamendo row must push JamendoBrowseView directly")
    }
}
