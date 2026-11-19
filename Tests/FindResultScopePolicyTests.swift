import XCTest

@testable import TonearmCore

final class FindResultScopePolicyTests: XCTestCase {
    func testInitialModeIsSongs() {
        XCTAssertEqual(FindResultScopePolicy.initialMode, .songs)
    }

    func testFreshStateStartsOnSongsAndKeepsExplicitChoice() {
        for choice in [LibraryBrowseMode.artists, .albums, .genres] {
            var s = FindResultScopeState()
            XCTAssertEqual(s.mode, .songs)
            s.select(choice)
            XCTAssertEqual(s.mode, choice)
            XCTAssertEqual(FindResultScopeState().mode, .songs)
        }
    }

    func testSongsShowIndividualRowsWhileArtistsGroup() {
        let rows = [1, 2].map { id in
            TrackRow(track: Track(id: Int64(id), albumId: 1, sourceId: 1, title: "T\(id)",
                                  trackNo: nil, discNo: nil, durationSec: nil, codec: nil,
                                  sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "t\(id)", genre: nil),
                     album: Album(id: 1, sourceId: 1, title: "A", artist: "Same Artist",
                                  albumArtist: nil, genre: nil, year: nil, artworkId: nil),
                     source: nil, asset: nil)
        }
        let songs = LibraryBrowse.sections(for: .songs, rows: rows).flatMap(\.entries)
        XCTAssertEqual(songs.map(\.kind), [.song, .song])
        XCTAssertTrue(songs.allSatisfy { $0.rows.count == 1 })
        XCTAssertEqual(LibraryBrowse.sections(for: .artists, rows: rows).flatMap(\.entries).count, 1)
    }

    func testFindViewConsumesPolicyAndExposesSelectedState() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                           encoding: .utf8)
        XCTAssertTrue(s.contains("browseMode: LibraryBrowseMode = FindResultScopePolicy.initialMode"))
        XCTAssertTrue(s.contains("accessibilityValue(selected ? \"selected\" : \"not selected\")"))
    }

    /// Mood and BPM/Key search results are always flat songs — their own controls select a
    /// mood/BPM/key, not a result shape. Grouping either into albums/artists/genres would
    /// scatter them across unrelated groups, the same problem the standalone Mood tab never had
    /// (it never routes through `LibraryBrowse` grouping at all).
    func testMoodAndMixModeHideTheScopePickerAndForceSongs() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                           encoding: .utf8)
        XCTAssertTrue(s.contains("if mode == .all {"))
        XCTAssertTrue(s.contains("if newMode == .sound || newMode == .mix { browseMode = .songs }"))
    }

    /// Genres isn't a useful Find result type; My Music's own Genres browsing is untouched.
    func testFindExcludesGenresFromItsResultTypeOptions() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                           encoding: .utf8)
        XCTAssertTrue(s.contains("LibraryBrowseMode.allCases.filter { $0 != .genres }"))
        XCTAssertTrue(s.contains("ForEach(findScopeOptions)"),
                     "findScopePicker must iterate the filtered options, not allCases directly")
    }

    /// The old inline Name/Mood/BPM-Key row is gone, replaced by a menu in the nav bar.
    /// Native iOS 26 toolbar chrome supplies the glass; the manual `.adaptiveGlass`
    /// nested a second GlassEffectContainer and flashed on every press.
    func testModeSelectionMovedToAToolbarMenu() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let find = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(find.contains(".toolbar { ToolbarItem(placement: .topBarTrailing) { FindModeMenu(mode: $mode) } }"))
        XCTAssertFalse(find.contains(".adaptiveGlass(cornerRadius: Metrics.glassCornerRadius)"),
                       "native toolbar glass replaces the manually nested GlassEffectContainer")
        let controls = try String(
            contentsOf: repo.appendingPathComponent("Sources/Features/MyMusic/MyMusicSearchControls.swift"),
            encoding: .utf8)
        XCTAssertFalse(controls.contains("modeSelector"),
                       "the inline mode row must be fully removed, not just unused")
    }
}
