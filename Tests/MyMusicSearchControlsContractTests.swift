#if !os(watchOS)
import XCTest

/// Find Mood reuses the single top search field instead of owning a second one.
final class MyMusicSearchControlsContractTests: XCTestCase {
    private func source() throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent("Sources/Features/MyMusic/MyMusicSearchControls.swift"),
                          encoding: .utf8)
    }

    func testSoundQueryOwnsNoTextField() throws {
        let s = try source()
        let tail = try XCTUnwrap(s.range(of: "struct MyMusicSoundQuery")).lowerBound
        XCTAssertFalse(String(s[tail...]).contains("TextField("))
        XCTAssertFalse(s.contains("TextField("))
    }

    func testTopFieldStaysVisibleInFindMood() throws {
        let s = try source()
        XCTAssertFalse(s.contains("if mode == .all { allSearchField }"))
        XCTAssertTrue(s.contains("if mode != .mix { allSearchField }"))
        XCTAssertFalse(s.contains("if newMode != .all { appState.searchText = \"\" }"))
    }

    func testTopFieldDrivesSoundModel() throws {
        let s = try source()
        XCTAssertTrue(s.contains(".onChange(of: appState.searchText)"))
        XCTAssertTrue(s.contains("soundModel.searchText = text"))
    }

    /// Find's Mood mode must work like the standalone Mood tab: pill selection, not free text
    /// alone, and never empty on first entry.
    func testSoundModeShowsMoodAndGenrePills() throws {
        let s = try source()
        XCTAssertTrue(s.contains("MoodPillPicker(pills: allMoodPills"))
        XCTAssertTrue(s.contains("MoodPillPicker(pills: genrePills"))
    }

    func testSoundModeDefaultsToCalmWhenNothingSelectedYet() throws {
        let s = try source()
        XCTAssertTrue(s.contains("MoodPillTaxonomy.energy.first(where: { $0.id == \"calm\" })"))
    }

    /// A stale pill selection from a previous sound-model instance must never survive — it would
    /// show as "selected" in the UI while having no effect on the freshly-built model's
    /// refinements.
    func testLeavingSoundModeClearsThePillSelection() throws {
        let s = try source()
        let guardRange = try XCTUnwrap(s.range(of: "guard mode == .sound else {"))
        let tail = String(s[guardRange.upperBound...].prefix(200))
        XCTAssertTrue(tail.contains("selectedMoodPillIDs = []"))
    }
}
#endif
