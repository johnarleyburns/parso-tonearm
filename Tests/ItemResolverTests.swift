import XCTest
@testable import TonearmCore

/// Fills the archive.org mock-coverage gap found auditing provider test parity: Subsonic, WebDAV,
/// Jellyfin, Plex and the four cloud drives all have a dedicated `*APITests.swift` exercising
/// request construction and response decoding with canned data — IAClient enforces a strict
/// archive.org-only host allowlist (Invariant #3), so there is no local-mock-server seam to point
/// it at the way those providers' own injectable `baseURL` allows; the equivalent, architecture-
/// respecting coverage is here instead, directly against `IAMetadataResponse`'s `Decodable`
/// conformance and `FileSelectionPolicy`'s pure track-selection logic — the two pieces
/// `ItemResolver.resolve(identifier:)` hands off to once `IAClient.shared.data(from:)` returns,
/// and the only parts of that path that don't require a real network call to exercise.
final class ItemResolverTests: XCTestCase {

    // MARK: - IAMetadataResponse decoding

    func testDecodesMetadataWithStringFields() throws {
        let json = """
        {"metadata":{"identifier":"test-item","title":"A Nice Recording","creator":"Some Artist",
        "mediatype":"audio","licenseurl":"https://creativecommons.org/licenses/by/4.0/",
        "date":"2020-05-01","genre":"Electronic"},
        "files":[{"name":"track.mp3","format":"VBR MP3","length":"120.5","size":"4800000"}],
        "server":"ia800000.us.archive.org","dir":"/1/items/test-item"}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(IAMetadataResponse.self, from: json)
        XCTAssertEqual(response.metadata?.identifier, "test-item")
        XCTAssertEqual(response.metadata?.title?.first, "A Nice Recording")
        XCTAssertEqual(response.metadata?.creator?.first, "Some Artist")
        XCTAssertEqual(response.metadata?.mediatype, "audio")
        XCTAssertEqual(response.files?.count, 1)
        XCTAssertEqual(response.files?.first?.name, "track.mp3")
    }

    /// IA's own API inconsistently returns a single creator as a bare string on some items and an
    /// array on others (multiple contributors) — `StringOrArray` exists specifically for this.
    func testDecodesMetadataWithArrayFields() throws {
        let json = """
        {"metadata":{"identifier":"test-item","title":["Side A","Side B"],
        "creator":["Artist One","Artist Two"],"mediatype":"audio"},"files":[]}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(IAMetadataResponse.self, from: json)
        XCTAssertEqual(response.metadata?.title?.first, "Side A")
        XCTAssertEqual(response.metadata?.creator?.first, "Artist One")
    }

    func testStringOrArrayFirstIsNilForEmptyString() throws {
        let json = #"{"metadata":{"identifier":"x","title":"","mediatype":"audio"},"files":[]}"#
            .data(using: .utf8)!
        let response = try JSONDecoder().decode(IAMetadataResponse.self, from: json)
        XCTAssertNil(response.metadata?.title?.first, "an empty title string means \"not provided,\" not a real title")
    }

    // MARK: - FileSelectionPolicy

    private func file(_ name: String, format: String? = nil, length: String? = nil, track: String? = nil) -> IAFile {
        IAFile(name: name, format: format, source: nil, original: nil, length: length, size: nil,
               title: nil, track: track, album: nil, artist: nil, bitrate: nil, height: nil)
    }

    func testPrefersFLACOverMP3WhenPreferFLACIsTrue() {
        let files = [file("song.mp3", format: "VBR MP3"), file("song.flac", format: "Free Lossless Audio")]
        let tracks = FileSelectionPolicy(preferFLAC: true).selectTracks(files: files, identifier: "item")
        XCTAssertEqual(tracks.count, 1, "both files are the same logical track (same basename stem)")
        XCTAssertEqual(tracks.first?.codec, "FLAC")
        XCTAssertEqual(tracks.first?.altFlacURL, nil, "the chosen file already is the FLAC — no separate alt needed")
    }

    func testPrefersMP3OverFLACWhenPreferFLACIsFalse() {
        let files = [file("song.mp3", format: "VBR MP3"), file("song.flac", format: "Free Lossless Audio")]
        let tracks = FileSelectionPolicy(preferFLAC: false).selectTracks(files: files, identifier: "item")
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "MP3")
        XCTAssertNotNil(tracks.first?.altFlacURL, "the FLAC variant is still offered as an upgrade path")
    }

    func testDistinctTracksAreNotCollapsedByFormat() {
        let files = [file("01 intro.mp3"), file("02 verse.mp3")]
        let tracks = FileSelectionPolicy(preferFLAC: true).selectTracks(files: files, identifier: "item")
        XCTAssertEqual(tracks.count, 2, "different basenames are different logical tracks")
    }

    func testSkipsPreviewSamplesAndRawIdentifierRips() {
        let files = [
            file("01 real track.mp3"),
            file("01 real track_sample.mp3"),
            file("item-identifier_disc1side1.flac"),
        ]
        let tracks = FileSelectionPolicy(preferFLAC: true).selectTracks(files: files, identifier: "item-identifier")
        XCTAssertEqual(tracks.map(\.title), ["real track"])
    }

    func testNonAudioExtensionsAreExcluded() {
        let files = [file("cover.jpg"), file("notes.txt"), file("track.mp3")]
        let tracks = FileSelectionPolicy(preferFLAC: true).selectTracks(files: files, identifier: "item")
        XCTAssertEqual(tracks.count, 1)
    }

    /// Opus is a candidate (the fetch→remux→CAF path, T2.x) but never AVFoundation-cold-playable —
    /// an Opus-only group still yields a track, explicitly flagged so the caller knows to remux it
    /// before first play rather than stream it directly.
    func testOpusOnlyGroupYieldsARemuxFlaggedTrack() {
        let files = [file("only.opus", format: "Ogg Opus")]
        let tracks = FileSelectionPolicy(preferFLAC: true).selectTracks(files: files, identifier: "item")
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "OPUS")
        XCTAssertTrue(tracks.first?.requiresRemux ?? false)
    }

    func testOpusIsNeverColdPlayChosenWhenAnotherFormatExists() {
        let files = [file("song.mp3"), file("song.opus", format: "Ogg Opus")]
        let tracks = FileSelectionPolicy(preferFLAC: true).selectTracks(files: files, identifier: "item")
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "MP3", "a mixed group must never cold-play Opus")
        XCTAssertFalse(tracks.first?.requiresRemux ?? true)
        XCTAssertNotNil(tracks.first?.opusURL, "still offered for the fetch-and-remux upgrade path")
    }

    func testTracksSortByTrackNumberWhenPresent() {
        let files = [file("B track.mp3", track: "2"), file("A track.mp3", track: "1")]
        let tracks = FileSelectionPolicy(preferFLAC: true).selectTracks(files: files, identifier: "item")
        XCTAssertEqual(tracks.map(\.title), ["A track", "B track"], "track number orders ahead of filename")
        XCTAssertEqual(tracks.map(\.trackNo), [1, 2])
    }

    func testTracksSortByTitleWhenNoTrackNumbersExist() {
        let files = [file("B track.mp3"), file("A track.mp3")]
        let tracks = FileSelectionPolicy(preferFLAC: true).selectTracks(files: files, identifier: "item")
        XCTAssertEqual(tracks.map(\.title), ["A track", "B track"], "no track numbers: falls back to title order")
    }
}
