import XCTest
@testable import TonearmCore

/// `FileSelectionPolicy` itself already has thorough coverage (`FileSelectionPolicyTests.swift`,
/// `InvariantTests.swift`, `OpusPolicyTests.swift`) — this file covers the two archive.org pieces
/// that didn't: `IAMetadataResponse`'s `Decodable` conformance (including IA's own API
/// inconsistently returning a single value as a bare string on some items and an array on others,
/// which `StringOrArray` exists to handle), and `selectTracks`' final sort order across multiple
/// tracks, which no existing test exercised.
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

    // MARK: - selectTracks sort order

    private func file(_ name: String, track: String? = nil) -> IAFile {
        IAFile(name: name, format: nil, source: nil, original: nil, length: nil, size: nil,
               title: nil, track: track, album: nil, artist: nil, bitrate: nil, height: nil)
    }

    func testTracksSortByTrackNumberWhenPresent() {
        let files = [file("B track.mp3", track: "2"), file("A track.mp3", track: "1")]
        let tracks = FileSelectionPolicy(preferFLAC: true).selectTracks(files: files, identifier: "item", itemArtist: nil)
        XCTAssertEqual(tracks.map(\.title), ["A track", "B track"], "track number orders ahead of filename")
        XCTAssertEqual(tracks.map(\.trackNo), [1, 2])
    }

    func testTracksSortByTitleWhenNoTrackNumbersExist() {
        let files = [file("B track.mp3"), file("A track.mp3")]
        let tracks = FileSelectionPolicy(preferFLAC: true).selectTracks(files: files, identifier: "item", itemArtist: nil)
        XCTAssertEqual(tracks.map(\.title), ["A track", "B track"], "no track numbers: falls back to title order")
    }
}
