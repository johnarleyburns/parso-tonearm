import XCTest
@testable import TonearmCore

final class IntentResolverTests: XCTestCase {
    func testPlaylistEmptyLibraryFailsBeforeMatching() {
        let resolution = IntentResolver.resolvePlaylist(named: "Road", playlists: [])

        XCTAssertEqual(resolution, .failure(.emptyLibrary(.playlist)))
    }

    func testArtistEmptyLibraryFailsBeforeMatching() {
        let resolution = IntentResolver.resolveArtist(named: "Bach", artists: [])

        XCTAssertEqual(resolution, .failure(.emptyLibrary(.artist)))
    }

    func testPlaylistExactMatchReturnsPlayCommand() {
        let resolution = IntentResolver.resolvePlaylist(named: "Road Trip", playlists: [
            .init(id: 1, title: "Quiet"),
            .init(id: 2, title: "Road Trip")
        ])

        XCTAssertEqual(resolution, .command(.playPlaylist(id: 2, title: "Road Trip")))
    }

    func testArtistMatchesCaseAndDiacritics() {
        let resolution = IntentResolver.resolveArtist(named: "Beyonce", artists: [
            .init(name: "Solange"),
            .init(name: "Beyoncé")
        ])

        XCTAssertEqual(resolution, .command(.playArtist(name: "Beyoncé")))
    }

    func testPlaylistNoMatchReturnsFailureWithTrimmedQuery() {
        let resolution = IntentResolver.resolvePlaylist(named: "  Metal  ", playlists: [
            .init(id: 1, title: "Ambient"),
            .init(id: 2, title: "Piano")
        ])

        XCTAssertEqual(resolution, .failure(.noMatch(kind: .playlist, query: "Metal")))
    }

    func testDuplicatePlaylistNamesAreAmbiguous() {
        let resolution = IntentResolver.resolvePlaylist(named: "Road Trip", playlists: [
            .init(id: 1, title: "Road Trip"),
            .init(id: 2, title: "road trip")
        ])

        XCTAssertEqual(
            resolution,
            .failure(.ambiguous(kind: .playlist, query: "Road Trip", matches: ["Road Trip", "road trip"]))
        )
    }

    func testPartialArtistNameCanBeAmbiguous() {
        let resolution = IntentResolver.resolveArtist(named: "Bach", artists: [
            .init(name: "Bach Cello Suites"),
            .init(name: "Bach Cantatas"),
            .init(name: "Debussy")
        ])

        XCTAssertEqual(
            resolution,
            .failure(.ambiguous(kind: .artist, query: "Bach", matches: ["Bach Cello Suites", "Bach Cantatas"]))
        )
    }

    func testEmptyQueryFails() {
        let resolution = IntentResolver.resolveArtist(named: "   ", artists: [
            .init(name: "Debussy")
        ])

        XCTAssertEqual(resolution, .failure(.emptyParameter(.artist)))
    }

    // MARK: - Song (docs/plans/carplay-voice-search-plan.md §1)

    func testSongEmptyLibraryFailsBeforeMatching() {
        let resolution = IntentResolver.resolveSong(title: "Yesterday", artist: nil, songs: [])

        XCTAssertEqual(resolution, .failure(.emptyLibrary(.song)))
    }

    func testSongExactTitleMatchReturnsPlayCommand() {
        let resolution = IntentResolver.resolveSong(title: "Hotel California", artist: nil, songs: [
            .init(trackId: 1, title: "Take It Easy", artist: "Eagles"),
            .init(trackId: 2, title: "Hotel California", artist: "Eagles")
        ])

        XCTAssertEqual(resolution, .command(.playSong(trackId: 2, title: "Hotel California", artist: "Eagles")))
    }

    /// The exact scenario the plan calls out: the same title recorded by
    /// two different artists. Without narrowing by the spoken artist first,
    /// this is ambiguous; with it, it resolves cleanly.
    func testSpokenArtistNarrowsAmbiguousTitleBeforeMatching() {
        let songs: [IntentResolver.SongCandidate] = [
            .init(trackId: 1, title: "Yesterday", artist: "The Beatles"),
            .init(trackId: 2, title: "Yesterday", artist: "Boyz II Men")
        ]

        XCTAssertEqual(
            IntentResolver.resolveSong(title: "Yesterday", artist: nil, songs: songs),
            .failure(.ambiguous(kind: .song, query: "Yesterday", matches: ["Yesterday", "Yesterday"]))
        )
        XCTAssertEqual(
            IntentResolver.resolveSong(title: "Yesterday", artist: "Beatles", songs: songs),
            .command(.playSong(trackId: 1, title: "Yesterday", artist: "The Beatles"))
        )
    }

    /// An artist Siri misheard (or that just doesn't match anything) must
    /// not make an otherwise-findable song fail outright — the narrowing
    /// only applies when it actually leaves a candidate.
    func testUnmatchedSpokenArtistFallsBackToSearchingEverySong() {
        let resolution = IntentResolver.resolveSong(
            title: "Hotel California",
            artist: "Some Mishearing",
            songs: [.init(trackId: 1, title: "Hotel California", artist: "Eagles")])

        XCTAssertEqual(resolution, .command(.playSong(trackId: 1, title: "Hotel California", artist: "Eagles")))
    }

    func testSongNoMatchReturnsFailure() {
        let resolution = IntentResolver.resolveSong(title: "Nonexistent Track", artist: nil, songs: [
            .init(trackId: 1, title: "Hotel California", artist: "Eagles")
        ])

        XCTAssertEqual(resolution, .failure(.noMatch(kind: .song, query: "Nonexistent Track")))
    }

    func testResumeAlwaysReturnsCommand() {
        XCTAssertEqual(IntentResolver.resolveResume(), .command(.resume))
    }

    func testAddSourceAcceptsArchiveURL() {
        let raw = " https://archive.org/details/foo "
        let resolution = IntentResolver.resolveAddSource(rawURL: raw)

        XCTAssertEqual(resolution, .command(.addSource(rawURL: "https://archive.org/details/foo")))
    }

    func testAddSourceRejectsForeignURL() {
        let resolution = IntentResolver.resolveAddSource(rawURL: "https://example.com/details/foo")

        XCTAssertEqual(resolution, .failure(.malformedURL("https://example.com/details/foo")))
    }

    func testSleepTimerBounds() {
        XCTAssertEqual(
            IntentResolver.resolveSleepTimer(minutes: IntentResolver.minimumSleepMinutes),
            .command(.setSleepTimer(.minutes(IntentResolver.minimumSleepMinutes)))
        )
        XCTAssertEqual(
            IntentResolver.resolveSleepTimer(minutes: IntentResolver.maximumSleepMinutes),
            .command(.setSleepTimer(.minutes(IntentResolver.maximumSleepMinutes)))
        )
        XCTAssertEqual(
            IntentResolver.resolveSleepTimer(minutes: 0),
            .failure(.invalidSleepTimerMinutes(0))
        )
        XCTAssertEqual(
            IntentResolver.resolveSleepTimer(minutes: IntentResolver.maximumSleepMinutes + 1),
            .failure(.invalidSleepTimerMinutes(IntentResolver.maximumSleepMinutes + 1))
        )
    }
}
