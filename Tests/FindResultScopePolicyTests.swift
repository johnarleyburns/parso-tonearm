import Testing

@testable import TonearmCore

@Suite struct FindResultScopePolicyTests {
    @Test func testInitialModeIsSongs() {
        #expect(FindResultScopePolicy.initialMode == .songs)
    }

    @Test func testFreshStateStartsOnSongsAndKeepsExplicitChoice() {
        for choice in [LibraryBrowseMode.artists, .albums, .genres] {
            var s = FindResultScopeState()
            #expect(s.mode == .songs)
            s.select(choice)
            #expect(s.mode == choice)
            #expect(FindResultScopeState().mode == .songs)
        }
    }

    @Test func testSongsShowIndividualRowsWhileArtistsGroup() {
        let rows = [1, 2].map { id in
            TrackRow(track: Track(id: Int64(id), albumId: 1, sourceId: 1, title: "T\(id)",
                                  trackNo: nil, discNo: nil, durationSec: nil, codec: nil,
                                  sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "t\(id)", genre: nil),
                     album: Album(id: 1, sourceId: 1, title: "A", artist: "Same Artist",
                                  albumArtist: nil, genre: nil, year: nil, artworkId: nil),
                     source: nil, asset: nil)
        }
        let songs = LibraryBrowse.sections(for: .songs, rows: rows).flatMap(\.entries)
        #expect(songs.map(\.kind) == [.song, .song])
        #expect(songs.allSatisfy { $0.rows.count == 1 })
        #expect(LibraryBrowse.sections(for: .artists, rows: rows).flatMap(\.entries).count == 1)
    }

    @Test func testFindViewConsumesPolicyAndExposesSelectedState() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                           encoding: .utf8)
        #expect(s.contains("browseMode: LibraryBrowseMode = FindResultScopePolicy.initialMode"))
        #expect(s.contains("accessibilityValue(selected ? \"selected\" : \"not selected\")"))
    }

    /// Mood and BPM/Key search results are always flat songs — their own controls select a
    /// mood/BPM/key, not a result shape. Grouping either into albums/artists/genres would
    /// scatter them across unrelated groups, the same problem the standalone Mood tab never had
    /// (it never routes through `LibraryBrowse` grouping at all).
    @Test func testMoodAndMixModeHideTheScopePickerAndForceSongs() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                           encoding: .utf8)
        #expect(s.contains("if mode == .all {"))
        #expect(s.contains("if newMode == .sound || newMode == .mix { browseMode = .songs }"))
    }

    /// Genres isn't a useful Find result type; My Music's own Genres browsing is untouched.
    @Test func testFindExcludesGenresFromItsResultTypeOptions() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                           encoding: .utf8)
        #expect(s.contains("LibraryBrowseMode.allCases.filter { $0 != .genres }"))
        #expect(s.contains("ForEach(findScopeOptions)"),
                     "findScopePicker must iterate the filtered options, not allCases directly")
    }

    /// The old inline Name/Mood/BPM-Key row is gone, replaced by a glass menu in the nav bar.
    @Test func testModeSelectionMovedToAToolbarGlassMenu() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let find = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                              encoding: .utf8)
        #expect(find.contains(".toolbar { ToolbarItem(placement: .topBarTrailing) { FindModeMenu(mode: $mode) } }"))
        #expect(find.contains(".adaptiveGlass(cornerRadius: Metrics.glassCornerRadius)"))
        let controls = try String(
            contentsOf: repo.appendingPathComponent("Sources/Features/MyMusic/MyMusicSearchControls.swift"),
            encoding: .utf8)
        #expect(!controls.contains("modeSelector"),
                       "the inline mode row must be fully removed, not just unused")
    }
}
