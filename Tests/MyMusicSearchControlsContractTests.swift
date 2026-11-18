#if !os(watchOS)
import Foundation
import Testing

/// Find Mood reuses the single top search field instead of owning a second one.
@Suite struct MyMusicSearchControlsContractTests {
    private func source() throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent("Sources/Features/MyMusic/MyMusicSearchControls.swift"),
                          encoding: .utf8)
    }

    @Test func testSoundQueryOwnsNoTextField() throws {
        let s = try source()
        let tail = try #require(s.range(of: "struct MyMusicSoundQuery")).lowerBound
        #expect(!(String(s[tail...]).contains("TextField(")))
        #expect(!s.contains("TextField("))
    }

    @Test func testTopFieldStaysVisibleInFindMood() throws {
        let s = try source()
        #expect(!s.contains("if mode == .all { allSearchField }"))
        #expect(s.contains("if mode != .mix { allSearchField }"))
        #expect(!s.contains("if newMode != .all { appState.searchText = \"\" }"))
    }

    @Test func testTopFieldDrivesSoundModel() throws {
        let s = try source()
        #expect(s.contains(".onChange(of: appState.searchText)"))
        #expect(s.contains("soundModel.searchText = text"))
    }

    /// Find's Mood mode must work like the standalone Mood tab: pill selection, not free text
    /// alone, and never empty on first entry. Mood and genre pills render as one merged,
    /// alphabetically-sorted, ucfirst-capitalized row (not two separate pickers).
    @Test func testSoundModeShowsMoodAndGenrePills() throws {
        let s = try source()
        #expect(s.contains("MoodPillPicker(pills: combinedMoodPills"))
        #expect(s.contains("(allMoodPills + genrePills)"))
    }

    @Test func testSoundModeDefaultsToCalmWhenNothingSelectedYet() throws {
        let s = try source()
        #expect(s.contains("MoodPillTaxonomy.energy.first(where: { $0.id == \"calm\" })"))
    }

    /// A stale pill selection from a previous sound-model instance must never survive — it would
    /// show as "selected" in the UI while having no effect on the freshly-built model's
    /// refinements.
    /// Mix-compatible ordering against the currently-playing track degrades gracefully instead
    /// of hard-blocking when that track isn't analyzed yet.
    @Test func testSoundModeGracefullyDegradesMixMatchingInsteadOfHardBlocking() throws {
        let s = try source()
        #expect(s.contains("model.setMatchingReferenceTrackID(trackID, enabled: isReadyForMatching(trackID))"))
        #expect(s.contains(".onChange(of: player.currentTrack?.id)"))
        #expect(s.contains(".onChange(of: appState.musicalInfoRevision)"))
        #expect(s.contains("info.bpm != nil && info.camelotKey != nil"))
    }

    @Test func testLeavingSoundModeClearsThePillSelection() throws {
        let s = try source()
        let guardRange = try #require(s.range(of: "guard mode == .sound else {"))
        let tail = String(s[guardRange.upperBound...].prefix(200))
        #expect(tail.contains("selectedMoodPillIDs = []"))
    }
}
#endif
