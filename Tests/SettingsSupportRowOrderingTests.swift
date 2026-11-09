import XCTest

/// `../parso-voxglass` places its Supporter purchase row second-to-last in Settings, right
/// before "About". Required deviation here: Tonearm's purchase row must be the FIRST row shown
/// in Settings — not wherever a naive port would put it. Source-inspection (no simulator needed)
/// is this repo's established convention for pinning view-body structure — see
/// `Tests/RootTabNavigationContractTests.swift` and `Tests/FavoriteAndHistoryTransientTrackTests.swift`'s
/// `FavoriteAndHistoryGuardOrderingTests`.
final class SettingsSupportRowOrderingTests: XCTestCase {
    private func settingsViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Settings/SettingsView.swift"),
            encoding: .utf8)
    }

    func testSupportDevelopmentCardIsTheFirstRowInSettingsBody() throws {
        let source = try settingsViewSource()
        let bodyStart = try XCTUnwrap(source.range(of: "var body: some View {"))
        let afterBody = source[bodyStart.upperBound...]

        let supportCardRange = try XCTUnwrap(afterBody.range(of: "SupportDevelopmentCard()"),
            "SupportDevelopmentCard() must still be called somewhere in SettingsView.body")

        for marker in ["watchCard", "settingsSection(\"Playback\"",
                       "settingsSection(\"Library & Storage\"",
                       "settingsSection(\"Account & About\"", "advancedSection"] {
            let markerRange = try XCTUnwrap(afterBody.range(of: marker),
                "expected marker \"\(marker)\" not found in SettingsView.body")
            XCTAssertLessThan(supportCardRange.lowerBound, markerRange.lowerBound,
                "SupportDevelopmentCard() must appear before \(marker) — it must be Settings' first row")
        }
    }

    func testSupportDevelopmentCardAppearsExactlyOnce() throws {
        let source = try settingsViewSource()
        let count = source.components(separatedBy: "SupportDevelopmentCard()").count - 1
        XCTAssertEqual(count, 1, "SupportDevelopmentCard() must not be duplicated — only its one call site should move")
    }
}
