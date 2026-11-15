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

    /// Mood search results are always flat songs — pills select a mood, not a result shape.
    /// Grouping a single mood's picks into albums/artists/genres would scatter them across
    /// unrelated groups, the same problem the standalone Mood tab never had (it never routes
    /// through `LibraryBrowse` grouping at all).
    func testMoodModeHidesTheScopePickerAndForcesSongs() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                           encoding: .utf8)
        XCTAssertTrue(s.contains("if mode != .sound {"))
        XCTAssertTrue(s.contains("if newMode == .sound { browseMode = .songs }"))
    }
}
