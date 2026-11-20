import Foundation
import Testing

/// Real report: the supporter badge rendered as the first element of the Listen tab's scrolling
/// body (under the large "Listen" title) instead of the integrated top-right glass toolbar
/// `../parso-voxglass` uses (a `ToolbarItemGroup` next to Settings, no manual glass modifier —
/// native iOS 26+ toolbar glass renders it). These tests pin the corrected shape via source
/// inspection (no simulator), matching this repo's established convention — see
/// `Tests/RootTabNavigationContractTests.swift`.
@Suite struct ListenViewSupporterBadgeTests {
    private func listenViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
            encoding: .utf8)
    }

    /// Pins the one gate on the badge: it must render only when
    /// `SupportDevelopmentStore.shared.isSupporter` is true, via the local
    /// `support` ObservedObject — never unconditionally.
    @Test func testBadgeIsGatedBehindIsSupporter() throws {
        let source = try listenViewSource()
        #expect(source.contains("@ObservedObject private var support = SupportDevelopmentStore.shared"),
            "ListenView must observe SupportDevelopmentStore.shared to react live to a purchase completing")

        let guardRange = try #require(source.range(of: "if support.isSupporter {"))
        let badgeCallRange = try #require(source.range(of: "supporterBadge"))
        #expect(guardRange.lowerBound < badgeCallRange.lowerBound,
            "the isSupporter guard must come before the first supporterBadge reference")
    }

    /// Pins the accessibility identifier the (hand-run, out-of-scope-here)
    /// UI regression suite would key off of.
    @Test func testBadgeHasStableAccessibilityIdentifier() throws {
        let source = try listenViewSource()
        let count = source.components(separatedBy: "\"listen.supporterBadge\"").count - 1
        #expect(count == 1, "listen.supporterBadge identifier must be present exactly once")
    }

    /// Pins the badge to the real nav-bar toolbar (matching voxglass) instead of the scrolling
    /// body — a `ToolbarItemGroup(placement: .primaryAction)` alongside Settings.
    @Test func testBadgeLivesInToolbarNotBody() throws {
        let source = try listenViewSource()
        let toolbarRange = try #require(source.range(of: ".toolbar {"))
        let groupRange = try #require(source.range(of: "ToolbarItemGroup(placement: .primaryAction)"))
        let guardRange = try #require(source.range(of: "if support.isSupporter {\n                    supporterBadge"))
        #expect(toolbarRange.lowerBound < groupRange.lowerBound,
            "the supporter badge's toolbar group must be declared inside a .toolbar { } block")
        #expect(groupRange.lowerBound < guardRange.lowerBound,
            "the isSupporter guard must sit inside the ToolbarItemGroup")
        #expect(source.contains("settingsButton"),
            "Settings must be factored into its own view alongside the badge in the same group")

        #expect(!source.contains("} else {\n                    Spacer().frame(height: 16)"),
            "the old body-inline badge/else-spacer branch must be gone")
    }

    /// Real report: the home page showed only a heart; the word "Supporter" was missing. A
    /// `Label` in a navigation-bar toolbar collapses to its icon, so the badge must spell the
    /// text out explicitly (the same HStack shape voxglass uses).
    func testBadgeRendersTheWordSupporterBesideTheHeart() throws {
        let source = try listenViewSource()
        let declRange = try XCTUnwrap(source.range(of: "private var supporterBadge: some View {"))
        let closeRange = try XCTUnwrap(source.range(of: "\n    }", range: declRange.upperBound..<source.endIndex))
        let body = source[declRange.upperBound..<closeRange.lowerBound]
        XCTAssertTrue(body.contains("Image(systemName: \"heart.fill\")"))
        XCTAssertTrue(body.contains("Text(\"Supporter\")"),
            "the toolbar renders a Label icon-only; the word must be an explicit Text")
        XCTAssertFalse(body.contains("Label(\"Supporter\""),
            "Label collapses to heart-only in a nav-bar toolbar")
    }

    /// No manual glass surface on the badge — native iOS 26+ toolbar glass renders it, matching
    /// voxglass's badge (which has no explicit glass modifier either).
    @Test func testBadgeHasNoManualGlassSurface() throws {
        let source = try listenViewSource()
        let declRange = try #require(source.range(of: "private var supporterBadge: some View {"))
        let closeRange = try #require(source.range(of: "\n    }", range: declRange.upperBound..<source.endIndex))
        let body = source[declRange.upperBound..<closeRange.lowerBound]
        #expect(!body.contains(".glassSurface"),
            "native toolbar glass replaces the manual glassSurface modifier")
    }
}
