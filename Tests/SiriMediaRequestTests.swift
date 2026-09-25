import XCTest
@testable import TonearmCore

final class SiriMediaRequestTests: XCTestCase {
    func testIdentifierRoundTrips() {
        let request = SiriMediaRequest(query: "Hotel California", artist: "Eagles", kind: .song)
        XCTAssertTrue(request.identifier.hasPrefix(SiriMediaRequest.identifierPrefix))
        XCTAssertEqual(SiriMediaRequest(identifier: request.identifier), request)
    }

    func testForeignIdentifiersAreRejected() {
        XCTAssertNil(SiriMediaRequest(identifier: "spotify:track:123"))
        XCTAssertNil(SiriMediaRequest(identifier: SiriMediaRequest.identifierPrefix + "not-base64!"))
    }

    func testWhitespaceIsTrimmedAndEmptyArtistDropped() {
        let request = SiriMediaRequest(query: "  Yesterday ", artist: "  ", kind: .song)
        XCTAssertEqual(request.query, "Yesterday")
        XCTAssertNil(request.artist)
    }

    func testNothingNamedMeansResume() {
        let request = SiriMediaRequest(query: nil, artist: nil, kind: .unspecified)
        XCTAssertTrue(request.isResume)
        XCTAssertEqual(request.attempts, [.resume])
    }

    func testArtistOnlyRequestPlaysTheArtist() {
        let request = SiriMediaRequest(query: nil, artist: "The Beatles", kind: .unspecified)
        XCTAssertEqual(request.attempts, [.artist("The Beatles")])
        XCTAssertEqual(request.displayTitle, "The Beatles")
    }

    func testClassifiedRequestsTryOnlyTheirKind() {
        XCTAssertEqual(SiriMediaRequest(query: "Road Trip", artist: nil, kind: .playlist).attempts,
                       [.playlist("Road Trip")])
        XCTAssertEqual(SiriMediaRequest(query: "Bach", artist: nil, kind: .artist).attempts,
                       [.artist("Bach")])
        XCTAssertEqual(SiriMediaRequest(query: "Yesterday", artist: "The Beatles", kind: .song).attempts,
                       [.song(title: "Yesterday", artist: "The Beatles")])
    }

    /// "Play Road Trip on Platterhead": Siri often can't tell a song from a
    /// playlist, so an unclassified request falls through song → artist →
    /// playlist.
    func testUnclassifiedRequestFallsThroughSongArtistPlaylist() {
        let request = SiriMediaRequest(query: "Road Trip", artist: nil, kind: .unspecified)
        XCTAssertEqual(request.attempts, [
            .song(title: "Road Trip", artist: nil),
            .artist("Road Trip"),
            .playlist("Road Trip")
        ])
    }

    func testDisplayTitleNamesSongAndArtist() {
        XCTAssertEqual(SiriMediaRequest(query: "Yesterday", artist: "The Beatles", kind: .song).displayTitle,
                       "Yesterday by The Beatles")
    }

    func testNoMatchFailuresAreClassifiedForFallThrough() {
        XCTAssertTrue(TonearmIntentError(.noMatch(kind: .song, query: "x")).isNoMatch)
        XCTAssertTrue(TonearmIntentError(.emptyLibrary(.playlist)).isNoMatch)
        XCTAssertFalse(TonearmIntentError(.ambiguous(kind: .song, query: "x", matches: ["a", "b"])).isNoMatch)
        XCTAssertFalse(TonearmIntentError("plain message").isNoMatch)
    }
}
