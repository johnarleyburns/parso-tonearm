#if !os(watchOS)
import XCTest

final class FindMixCopyAndLayoutContractTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    func testRenamedCopyAndStableIdentifiers() throws {
        let s = try source("Sources/Features/MyMusic/MyMusicSearchControls.swift")
        for new in ["\"BPM/Key\"", "\"Track BPM\"", "\"Camelot Key\""] {
            XCTAssertTrue(s.contains(new), new)
        }
        for old in ["\"Find Mix\"", "\"Mix BPM\"", "\"Mix Key\""] {
            XCTAssertFalse(s.contains(old), old)
        }
        for id in ["find.mode.all", "\"mymusic.mix.bpm\"", "\"mymusic.mix.key\""] {
            XCTAssertTrue(s.contains(id), id)
        }
        XCTAssertTrue(s.contains("\"find.mode.mix\""))
        for old in ["\"By Name\"", "\"By Mood\"", "\"By BPM/Key\""] {
            XCTAssertFalse(s.contains(old), old)
        }
        for label in ["\"Name\"", "\"Mood\"", "\"BPM/Key\""] {
            XCTAssertTrue(s.contains("= " + label), label)
        }
    }

    func testContentTopIsPinnedWithReservedHeight() throws {
        let find = try source("Sources/Features/Find/FindView.swift")
        XCTAssertTrue(find.contains(".frame(minHeight: Self.contentMinHeight, alignment: .top)"))
        let lib = try source("Sources/Features/Library/LibraryView.swift")
        XCTAssertTrue(lib.contains(".frame(minHeight: Self.contentAreaMinHeight, alignment: .top)"))
        XCTAssertFalse(lib.contains(".padding(.top, 60)"), "loading/empty must be top-pinned like results")
    }

    /// Real report: the search box has no top margin in Name mode, overlaps the bottom half of
    /// Find in Mood mode, and overlaps the entire screen from the top in BPM/Key mode (its header
    /// — search field + mode selector + two full BPM/Camelot chip rows — is the tallest of the
    /// three). Root cause: the header VStack was `.fixedSize(vertical: true)`, forcing it to
    /// claim its full natural height unconditionally, while the results area below it had an
    /// unconditional `minHeight` floor (`testContentTopIsPinnedWithReservedHeight`, above) —
    /// neither could compress, and nothing here scrolls to absorb the combined overflow, so
    /// whenever header height + that floor exceeded the available screen height (worse under a
    /// tall mode, worse again once the keyboard appears), the header rendered past the results
    /// area instead of yielding it space. Removing `.fixedSize` lets the header compress first,
    /// so the reserved results floor this screen already guarantees is never pushed off-screen.
    func testHeaderCanCompressInsteadOfForcingOverlapOntoResults() throws {
        let find = try source("Sources/Features/Find/FindView.swift")
        XCTAssertFalse(find.contains(".fixedSize(horizontal: false, vertical: true)"),
                       "the header must be able to compress when space is tight, or a tall mode " +
                       "forces the whole screen past the available height instead of yielding " +
                       "space to the reserved results area below")
    }

    /// Mood mode used to render two separate pill rows (taxonomy/era-vibe pills, then genre
    /// pills); they're now one merged, alphabetically-sorted, consistently-capitalized row.
    func testMoodPillsAreOneMergedUcfirstSortedRow() throws {
        let s = try source("Sources/Features/MyMusic/MyMusicSearchControls.swift")
        XCTAssertTrue(s.contains("combinedMoodPills"))
        XCTAssertTrue(s.contains("combinedPillSelectionBinding"))
        XCTAssertFalse(s.contains("if !genrePills.isEmpty"),
                       "genre pills must no longer render as a separate, conditional row")
        XCTAssertEqual(s.components(separatedBy: "MoodPillPicker(pills:").count - 1, 1,
                       "exactly one MoodPillPicker call left in Mood mode")
    }

    /// "Directly play all my Find results into the queue" — Find opts into LibraryView's
    /// Play All action (My Music's own use of LibraryView stays opt-out/default, unaffected).
    func testFindOptsIntoPlayAllAndLibraryViewImplementsItByReplacingTheQueue() throws {
        let find = try source("Sources/Features/Find/FindView.swift")
        XCTAssertTrue(find.contains("showsPlayAllButton: true"))
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        XCTAssertFalse(myMusic.contains("showsPlayAllButton"),
                       "My Music's own browsing must not gain this button as a side effect")
        let lib = try source("Sources/Features/Library/LibraryView.swift")
        XCTAssertTrue(lib.contains("showsPlayAllButton: Bool = false"),
                     "default must be off so only an explicit opt-in (Find) shows it")
        XCTAssertTrue(lib.contains("player.play(tracks: fresh, startAt: 0, source: .library)"),
                     "must reuse the same replace-queue-and-play pattern as LibraryGroupDetailView's own Play button")
    }

    /// 320 (this screen's old floor, matching `LibraryView.contentAreaMinHeight` only by
    /// coincidence — that one lives inside LibraryView's own ScrollView and can never force this
    /// screen to overflow the way this one, applied directly in the outer non-scrolling VStack,
    /// could) left no room for BPM/Key's two-chip-row header on a small device even once the
    /// header itself can compress. The floor only needs to keep the empty/placeholder state from
    /// looking cramped, not match that unrelated constant.
    func testResultsFloorLeavesRoomForATallHeaderOnASmallDevice() throws {
        let find = try source("Sources/Features/Find/FindView.swift")
        let pattern = #"static let contentMinHeight: CGFloat = (\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(find.startIndex..., in: find)
        let match = try XCTUnwrap(regex.firstMatch(in: find, range: range),
                                  "contentMinHeight must still be declared as a CGFloat literal")
        let valueRange = try XCTUnwrap(Range(match.range(at: 1), in: find))
        let value = try XCTUnwrap(Double(find[valueRange]))
        XCTAssertLessThan(value, 320, "the old floor left no room for a tall header on a small device")
    }

    /// Real report: the collapsed toolbar menu showed its text label ("Name"/"Mood"/"BPM/Key")
    /// at all times; the owner wanted only an icon in the collapsed state, with text appearing
    /// only once the menu is actually open.
    func testModeMenuCollapsedShowsOnlyAnIconNotText() throws {
        let find = try source("Sources/Features/Find/FindView.swift")
        XCTAssertFalse(find.contains("Text(mode.rawValue)"),
                       "the collapsed toolbar button must not show the mode's text label")
        XCTAssertTrue(find.contains("Image(systemName: mode.icon)"),
                      "the collapsed toolbar button must show only an icon")
        let controls = try source("Sources/Features/MyMusic/MyMusicSearchControls.swift")
        XCTAssertTrue(controls.contains("var icon: String"))
        // Still shown as text once the menu is open, per-option.
        XCTAssertTrue(find.contains("Text(option.rawValue)"))
        XCTAssertTrue(find.contains("Label(option.rawValue, systemImage: \"checkmark\")"))
    }

    /// Real report: the mode menu flashed often. Root cause: it was a computed property
    /// inlined into `FindView.body`, so it got rebuilt whenever *any* unrelated `@Published`
    /// property changed on the `appState` object `FindView` observes via `@EnvironmentObject`
    /// (e.g. the 5-second watch transfer tick, regardless of which tab is visible) — a
    /// standalone `View` fed only the `mode` binding it needs isolates it from that churn.
    func testModeMenuIsAStandaloneViewNotInlinedIntoFindViewsBody() throws {
        let find = try source("Sources/Features/Find/FindView.swift")
        XCTAssertTrue(find.contains("struct FindModeMenu: View"),
                      "must be its own View, not a computed property on FindView")
        XCTAssertTrue(find.contains("FindModeMenu(mode: $mode)"))
        XCTAssertFalse(find.contains("private var modeMenu: some View"),
                       "the old inlined-into-FindView.body version must be gone")
    }
}
#endif
