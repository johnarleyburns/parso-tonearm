import Foundation
import Testing

/// `../parso-voxglass` places its Supporter purchase row second-to-last in Settings, right
/// before "About". Required deviation here: Tonearm's purchase row must be the FIRST row shown
/// in Settings — not wherever a naive port would put it. Source-inspection (no simulator needed)
/// is this repo's established convention for pinning view-body structure — see
/// `Tests/RootTabNavigationContractTests.swift` and `Tests/FavoriteAndHistoryTransientTrackTests.swift`'s
/// `FavoriteAndHistoryGuardOrderingTests`.
@Suite struct SettingsSupportRowOrderingTests {
    private func settingsViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Settings/SettingsView.swift"),
            encoding: .utf8)
    }

    @Test func testSupportDevelopmentCardIsTheFirstRowInSettingsBody() throws {
        let source = try settingsViewSource()
        let bodyStart = try #require(source.range(of: "var body: some View {"))
        let afterBody = source[bodyStart.upperBound...]

        let supportCardRange = try #require(afterBody.range(of: "SupportDevelopmentCard()"),
            "SupportDevelopmentCard() must still be called somewhere in SettingsView.body")

        for marker in ["watchCard", "settingsSection(\"Playback\"",
                       "settingsSection(\"Account & About\"", "advancedSection"] {
            let markerRange = try #require(afterBody.range(of: marker),
                "expected marker \"\(marker)\" not found in SettingsView.body")
            #expect(supportCardRange.lowerBound < markerRange.lowerBound,
                "SupportDevelopmentCard() must appear before \(marker) — it must be Settings' first row")
        }
    }

    @Test func testSupportDevelopmentCardAppearsExactlyOnce() throws {
        let source = try settingsViewSource()
        let count = source.components(separatedBy: "SupportDevelopmentCard()").count - 1
        #expect(count == 1, "SupportDevelopmentCard() must not be duplicated — only its one call site should move")
    }
}

@Suite struct SettingsVoxglassLayoutTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Features/Settings/SettingsView.swift"), encoding: .utf8)
    }

    private func sectionHelperBody(_ s: String) throws -> String {
        let start = try #require(s.range(of: "private func settingsSection<"))
        let end = try #require(s.range(of: "private func sectionDetail"))
        return String(s[start.lowerBound..<end.lowerBound])
    }

    @Test func testSectionOrder() throws {
        let s = try source()
        let body = try #require(s.range(of: "var body: some View {"))
        let after = s[body.upperBound...]
        var last = after.startIndex
        for m in ["settingsSection(\"Support\"", "settingsSection(\"Storage & Cache\"",
                  "settingsSection(\"Playback\"",
                  "settingsSection(\"Apple Watch\"", "settingsSection(\"Account & About\"",
                  "settingsSection(\"Advanced\""] {
            let r = try #require(after.range(of: m), "\(m)")
            #expect(last < r.lowerBound, "\(m)")
            last = r.lowerBound
        }
        #expect(!after.contains("Section {"), "no bare un-headered Section wrappers")
    }

    @Test func testHeaderHasNoIconAndCardIsStroked() throws {
        let s = try source()
        let f = try sectionHelperBody(s)
        #expect(!f.contains("Image(systemName"))
        #expect(!f.contains("Divider()"))
        #expect(!s.contains("sectionIcon"))
        #expect(f.contains("cornerRadius: 20"))
        #expect(!f.contains("cornerRadius: 18"))
        #expect(f.contains(".stroke(Palette.hairline, lineWidth: 1)"))
    }

    @Test func testNoVoxglassTokenLeakage() throws {
        let s = try source()
        for t in ["Palette.surfaceLine", "Palette.ink2", "Palette.ink3", "Palette.brass", "VoxglassTheme"] {
            #expect(!s.contains(t), "\(t)")
        }
    }
}
