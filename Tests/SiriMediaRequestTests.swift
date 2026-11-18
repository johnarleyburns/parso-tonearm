import Testing
@testable import TonearmCore

@Suite struct SiriMediaRequestTests {
    @Test func testIdentifierRoundTrips() {
        let request = SiriMediaRequest(query: "Hotel California", artist: "Eagles", kind: .song)
        #expect(request.identifier.hasPrefix(SiriMediaRequest.identifierPrefix))
        #expect(SiriMediaRequest(identifier: request.identifier) == request)
    }

    @Test func testForeignIdentifiersAreRejected() {
        #expect(SiriMediaRequest(identifier: "spotify:track:123") == nil)
        #expect(SiriMediaRequest(identifier: SiriMediaRequest.identifierPrefix + "not-base64!") == nil)
    }

    @Test func testWhitespaceIsTrimmedAndEmptyArtistDropped() {
        let request = SiriMediaRequest(query: "  Yesterday ", artist: "  ", kind: .song)
        #expect(request.query == "Yesterday")
        #expect(request.artist == nil)
    }

    @Test func testNothingNamedMeansResume() {
        let request = SiriMediaRequest(query: nil, artist: nil, kind: .unspecified)
        #expect(request.isResume)
        #expect(request.attempts == [.resume])
    }

    @Test func testArtistOnlyRequestPlaysTheArtist() {
        let request = SiriMediaRequest(query: nil, artist: "The Beatles", kind: .unspecified)
        #expect(request.attempts == [.artist("The Beatles")])
        #expect(request.displayTitle == "The Beatles")
    }

    @Test func testClassifiedRequestsTryOnlyTheirKind() {
        #expect(SiriMediaRequest(query: "Road Trip", artist: nil, kind: .playlist).attempts ==
                       [.playlist("Road Trip")])
        #expect(SiriMediaRequest(query: "Bach", artist: nil, kind: .artist).attempts ==
                       [.artist("Bach")])
        #expect(SiriMediaRequest(query: "Yesterday", artist: "The Beatles", kind: .song).attempts ==
                       [.song(title: "Yesterday", artist: "The Beatles")])
    }

    /// "Play Road Trip on Platterhead": Siri often can't tell a song from a
    /// playlist, so an unclassified request falls through song → artist →
    /// playlist.
    @Test func testUnclassifiedRequestFallsThroughSongArtistPlaylist() {
        let request = SiriMediaRequest(query: "Road Trip", artist: nil, kind: .unspecified)
        #expect(request.attempts == [
            .song(title: "Road Trip", artist: nil),
            .artist("Road Trip"),
            .playlist("Road Trip")
        ])
    }

    @Test func testDisplayTitleNamesSongAndArtist() {
        #expect(SiriMediaRequest(query: "Yesterday", artist: "The Beatles", kind: .song).displayTitle ==
                       "Yesterday by The Beatles")
    }

    @Test func testNoMatchFailuresAreClassifiedForFallThrough() {
        #expect(TonearmIntentError(.noMatch(kind: .song, query: "x")).isNoMatch)
        #expect(TonearmIntentError(.emptyLibrary(.playlist)).isNoMatch)
        #expect(!TonearmIntentError(.ambiguous(kind: .song, query: "x", matches: ["a", "b"])).isNoMatch)
        #expect(!TonearmIntentError("plain message").isNoMatch)
    }
}
