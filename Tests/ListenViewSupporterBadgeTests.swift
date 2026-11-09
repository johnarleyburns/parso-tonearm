import XCTest

/// Audit finding: Tonearm's home-view supporter badge already matches `../parso-voxglass`'s
/// workflow shape (a heart-icon "Supporter" label shown only when the one-time, non-gating
/// contribution flag is set, with a stable accessibility identifier) — this is a pure
/// test-coverage gap, not a feature gap. Nothing previously pinned the badge's visibility logic
/// or identifier, so a future refactor of `ListenView.swift` could silently drop either with
/// nothing catching it on `swift test`, the only gate that runs on every commit. Source-
/// inspection (no simulator) matches this repo's established convention — see
/// `Tests/RootTabNavigationContractTests.swift` and `Tests/FavoriteAndHistoryTransientTrackTests.swift`'s
/// `FavoriteAndHistoryGuardOrderingTests`.
final class ListenViewSupporterBadgeTests: XCTestCase {
    private func listenViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
            encoding: .utf8)
    }

    /// Pins the one gate on the badge: it must render only when
    /// `SupportDevelopmentStore.shared.isSupporter` is true, via the local
    /// `support` ObservedObject — never unconditionally.
    func testBadgeIsGatedBehindIsSupporter() throws {
        let source = try listenViewSource()
        XCTAssertTrue(source.contains("@ObservedObject private var support = SupportDevelopmentStore.shared"),
            "ListenView must observe SupportDevelopmentStore.shared to react live to a purchase completing")

        let guardRange = try XCTUnwrap(source.range(of: "if support.isSupporter {"))
        let badgeCallRange = try XCTUnwrap(source.range(of: "supporterBadge"))
        XCTAssertLessThan(guardRange.lowerBound, badgeCallRange.lowerBound,
            "the isSupporter guard must come before the first supporterBadge reference")
    }

    /// Pins the accessibility identifier the (hand-run, out-of-scope-here)
    /// UI regression suite would key off of.
    func testBadgeHasStableAccessibilityIdentifier() throws {
        let source = try listenViewSource()
        let count = source.components(separatedBy: "\"listen.supporterBadge\"").count - 1
        XCTAssertEqual(count, 1, "listen.supporterBadge identifier must be present exactly once")
    }

    /// Guards against a regression where the badge (or its height-preserving
    /// else-branch spacer) becomes unconditional.
    func testElseBranchDoesNotAlsoShowTheBadge() throws {
        let source = try listenViewSource()
        let guardLine = try XCTUnwrap(source.range(of: "if support.isSupporter {\n                    supporterBadge"))
        let elseRange = try XCTUnwrap(source.range(of: "} else {\n                    Spacer()"))
        XCTAssertLessThan(guardLine.lowerBound, elseRange.lowerBound)
    }
}
