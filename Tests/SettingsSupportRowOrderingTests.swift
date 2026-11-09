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
                       "settingsSection(\"Library\"",
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

final class SettingsVoxglassLayoutTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Features/Settings/SettingsView.swift"), encoding: .utf8)
    }

    private func sectionHelperBody(_ s: String) throws -> String {
        let start = try XCTUnwrap(s.range(of: "private func settingsSection<"))
        let end = try XCTUnwrap(s.range(of: "private func sectionDetail"))
        return String(s[start.lowerBound..<end.lowerBound])
    }

    func testSectionOrder() throws {
        let s = try source()
        let body = try XCTUnwrap(s.range(of: "var body: some View {"))
        let after = s[body.upperBound...]
        var last = after.startIndex
        for m in ["settingsSection(\"Support\"", "settingsSection(\"Storage & Cache\"",
                  "settingsSection(\"Playback\"", "settingsSection(\"Library\"",
                  "settingsSection(\"Apple Watch\"", "settingsSection(\"Account & About\"",
                  "settingsSection(\"Advanced\""] {
            let r = try XCTUnwrap(after.range(of: m), m)
            XCTAssertLessThan(last, r.lowerBound, m)
            last = r.lowerBound
        }
        XCTAssertFalse(after.contains("Section {"), "no bare un-headered Section wrappers")
    }

    func testHeaderHasNoIconAndCardIsStroked() throws {
        let s = try source()
        let f = try sectionHelperBody(s)
        XCTAssertFalse(f.contains("Image(systemName"))
        XCTAssertFalse(f.contains("Divider()"))
        XCTAssertFalse(s.contains("sectionIcon"))
        XCTAssertTrue(f.contains("cornerRadius: 20"))
        XCTAssertFalse(f.contains("cornerRadius: 18"))
        XCTAssertTrue(f.contains(".stroke(Palette.hairline, lineWidth: 1)"))
    }

    func testNoVoxglassTokenLeakage() throws {
        let s = try source()
        for t in ["Palette.surfaceLine", "Palette.ink2", "Palette.ink3", "Palette.brass", "VoxglassTheme"] {
            XCTAssertFalse(s.contains(t), t)
        }
    }
}
