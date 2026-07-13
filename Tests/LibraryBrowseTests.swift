import XCTest

@testable import Tonearm

final class LibraryBrowseTests: XCTestCase {

    func testEmptyLibraryProducesNoSections() {
        for mode in LibraryBrowseMode.allCases {
            XCTAssertEqual(LibraryBrowse.sections(for: mode, rows: []), [], mode.rawValue)
        }
    }

    func testIndexTitleBucketsASCIIAndOtherLeadingScalars() {
        XCTAssertEqual(LibraryBrowse.indexTitle(for: "Álvaro Soler"), "A")
        XCTAssertEqual(LibraryBrowse.indexTitle(for: "the beatles"), "T")
        XCTAssertEqual(LibraryBrowse.indexTitle(for: "3 Doors Down"), "#")
        XCTAssertEqual(LibraryBrowse.indexTitle(for: "!Action Pact!"), "#")
        XCTAssertEqual(LibraryBrowse.indexTitle(for: "東京事変"), "#")
        XCTAssertEqual(LibraryBrowse.indexTitle(for: "   "), "#")
    }

    func testArtistsGroupAndSortByFoldedArticleAwareName() {
        let rows = [
            row(id: 1, title: "Come Together", artist: "The Beatles"),
            row(id: 2, title: "El Mismo Sol", artist: "Álvaro Soler"),
            row(id: 3, title: "Kryptonite", artist: "3 Doors Down"),
        ]

        let sections = LibraryBrowse.sections(for: .artists, rows: rows)

        XCTAssertEqual(sections.map(\.indexTitle), ["A", "B", "#"])
        XCTAssertEqual(sections.flatMap(\.entries).map(\.title),
                       ["Álvaro Soler", "The Beatles", "3 Doors Down"])
    }

    func testSongsSortStablyForDuplicateTitles() {
        let rows = [
            row(id: 1, title: "Same", artist: "A", sortKey: "same"),
            row(id: 2, title: "Same", artist: "B", sortKey: "same"),
            row(id: 3, title: "Another", artist: "C", sortKey: "another"),
        ]

        let entries = LibraryBrowse.sections(for: .songs, rows: rows).flatMap(\.entries)

        XCTAssertEqual(entries.map(\.title), ["Another", "Same", "Same"])
        XCTAssertEqual(entries.filter { $0.title == "Same" }.map { $0.rows[0].id }, [1, 2])
    }

    func testOneArtistWithOneThousandAlbums() {
        let rows = (0..<1_000).map { index in
            row(id: Int64(index + 1),
                title: "Track \(index)",
                artist: "One Artist",
                albumTitle: String(format: "Album %04d", index),
                albumId: Int64(index + 1),
                sortKey: String(format: "%04d", index))
        }

        let artistEntries = LibraryBrowse.sections(for: .artists, rows: rows).flatMap(\.entries)
        let albumEntries = LibraryBrowse.sections(for: .albums, rows: rows).flatMap(\.entries)

        XCTAssertEqual(artistEntries.count, 1)
        XCTAssertEqual(artistEntries.first?.title, "One Artist")
        XCTAssertEqual(artistEntries.first?.subtitle, "1000 albums")
        XCTAssertEqual(artistEntries.first?.rows.count, 1_000)
        XCTAssertEqual(albumEntries.count, 1_000)
    }

    func testCompilationAlbumsGroupUnderAlbumArtist() {
        let rows = [
            row(id: 1, title: "Track A", artist: "Track Artist A", albumArtist: "Various Artists"),
            row(id: 2, title: "Track B", artist: "Track Artist B", albumArtist: "Various Artists"),
        ]

        let entries = LibraryBrowse.sections(for: .artists, rows: rows).flatMap(\.entries)

        XCTAssertEqual(entries.map(\.title), ["Various Artists"])
        XCTAssertEqual(entries.first?.rows.map { $0.track.title }, ["Track A", "Track B"])
    }

    func testGenresPreferTrackThenAlbumAndGroupUnknowns() {
        let rows = [
            row(id: 1, title: "Track Folk", artist: "A", albumGenre: "Album Rock", trackGenre: "Folk"),
            row(id: 2, title: "Album Rock Track", artist: "B", albumGenre: "Album Rock"),
            row(id: 3, title: "Unknown", artist: "C"),
        ]

        let entries = LibraryBrowse.sections(for: .genres, rows: rows).flatMap(\.entries)

        XCTAssertEqual(entries.map(\.title), ["Album Rock", "Folk", "Unknown Genre"])
        XCTAssertEqual(entries.first { $0.title == "Folk" }?.rows.map { $0.track.title }, ["Track Folk"])
        XCTAssertEqual(entries.first { $0.title == "Album Rock" }?.rows.map { $0.track.title },
                       ["Album Rock Track"])
    }

    private func row(id: Int64,
                     title: String,
                     artist: String,
                     albumTitle: String = "Album",
                     albumArtist: String? = nil,
                     albumGenre: String? = nil,
                     trackGenre: String? = nil,
                     albumId: Int64? = 1,
                     trackNo: Int? = nil,
                     discNo: Int? = nil,
                     sortKey: String? = nil) -> TrackRow {
        let album = Album(id: albumId, sourceId: 1, title: albumTitle,
                          artist: artist, albumArtist: albumArtist,
                          genre: albumGenre, year: nil, artworkId: nil)
        let track = Track(id: id, albumId: albumId, sourceId: 1, title: title,
                          trackNo: trackNo, discNo: discNo, durationSec: nil,
                          codec: nil, sampleRate: nil, bitDepthOrBitrate: nil,
                          sortKey: sortKey ?? title.lowercased(),
                          genre: trackGenre)
        return TrackRow(track: track, album: album, source: nil, asset: nil)
    }
}
