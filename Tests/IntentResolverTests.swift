import Testing
@testable import TonearmCore

@Suite struct IntentResolverTests {
    @Test func testPlaylistEmptyLibraryFailsBeforeMatching() {
        let resolution = IntentResolver.resolvePlaylist(named: "Road", playlists: [])

        #expect(resolution == .failure(.emptyLibrary(.playlist)))
    }

    @Test func testArtistEmptyLibraryFailsBeforeMatching() {
        let resolution = IntentResolver.resolveArtist(named: "Bach", artists: [])

        #expect(resolution == .failure(.emptyLibrary(.artist)))
    }

    @Test func testPlaylistExactMatchReturnsPlayCommand() {
        let resolution = IntentResolver.resolvePlaylist(named: "Road Trip", playlists: [
            .init(id: 1, title: "Quiet"),
            .init(id: 2, title: "Road Trip")
        ])

        #expect(resolution == .command(.playPlaylist(id: 2, title: "Road Trip")))
    }

    @Test func testArtistMatchesCaseAndDiacritics() {
        let resolution = IntentResolver.resolveArtist(named: "Beyonce", artists: [
            .init(name: "Solange"),
            .init(name: "Beyoncé")
        ])

        #expect(resolution == .command(.playArtist(name: "Beyoncé")))
    }

    @Test func testPlaylistNoMatchReturnsFailureWithTrimmedQuery() {
        let resolution = IntentResolver.resolvePlaylist(named: "  Metal  ", playlists: [
            .init(id: 1, title: "Ambient"),
            .init(id: 2, title: "Piano")
        ])

        #expect(resolution == .failure(.noMatch(kind: .playlist, query: "Metal")))
    }

    @Test func testDuplicatePlaylistNamesAreAmbiguous() {
        let resolution = IntentResolver.resolvePlaylist(named: "Road Trip", playlists: [
            .init(id: 1, title: "Road Trip"),
            .init(id: 2, title: "road trip")
        ])

        #expect(
            resolution ==
            .failure(.ambiguous(kind: .playlist, query: "Road Trip", matches: ["Road Trip", "road trip"]))
        )
    }

    @Test func testPartialArtistNameCanBeAmbiguous() {
        let resolution = IntentResolver.resolveArtist(named: "Bach", artists: [
            .init(name: "Bach Cello Suites"),
            .init(name: "Bach Cantatas"),
            .init(name: "Debussy")
        ])

        #expect(
            resolution ==
            .failure(.ambiguous(kind: .artist, query: "Bach", matches: ["Bach Cello Suites", "Bach Cantatas"]))
        )
    }

    @Test func testEmptyQueryFails() {
        let resolution = IntentResolver.resolveArtist(named: "   ", artists: [
            .init(name: "Debussy")
        ])

        #expect(resolution == .failure(.emptyParameter(.artist)))
    }

    // MARK: - Song (docs/plans/carplay-voice-search-plan.md §1)

    @Test func testSongEmptyLibraryFailsBeforeMatching() {
        let resolution = IntentResolver.resolveSong(title: "Yesterday", artist: nil, songs: [])

        #expect(resolution == .failure(.emptyLibrary(.song)))
    }

    @Test func testSongExactTitleMatchReturnsPlayCommand() {
        let resolution = IntentResolver.resolveSong(title: "Hotel California", artist: nil, songs: [
            .init(trackId: 1, title: "Take It Easy", artist: "Eagles"),
            .init(trackId: 2, title: "Hotel California", artist: "Eagles")
        ])

        #expect(resolution == .command(.playSong(trackId: 2, title: "Hotel California", artist: "Eagles")))
    }

    /// The exact scenario the plan calls out: the same title recorded by
    /// two different artists. Without narrowing by the spoken artist first,
    /// this is ambiguous; with it, it resolves cleanly.
    @Test func testSpokenArtistNarrowsAmbiguousTitleBeforeMatching() {
        let songs: [IntentResolver.SongCandidate] = [
            .init(trackId: 1, title: "Yesterday", artist: "The Beatles"),
            .init(trackId: 2, title: "Yesterday", artist: "Boyz II Men")
        ]

        #expect(
            IntentResolver.resolveSong(title: "Yesterday", artist: nil, songs: songs) ==
            .failure(.ambiguous(kind: .song, query: "Yesterday", matches: ["Yesterday", "Yesterday"]))
        )
        #expect(
            IntentResolver.resolveSong(title: "Yesterday", artist: "Beatles", songs: songs) ==
            .command(.playSong(trackId: 1, title: "Yesterday", artist: "The Beatles"))
        )
    }

    /// An artist Siri misheard (or that just doesn't match anything) must
    /// not make an otherwise-findable song fail outright — the narrowing
    /// only applies when it actually leaves a candidate.
    @Test func testUnmatchedSpokenArtistFallsBackToSearchingEverySong() {
        let resolution = IntentResolver.resolveSong(
            title: "Hotel California",
            artist: "Some Mishearing",
            songs: [.init(trackId: 1, title: "Hotel California", artist: "Eagles")])

        #expect(resolution == .command(.playSong(trackId: 1, title: "Hotel California", artist: "Eagles")))
    }

    @Test func testSongNoMatchReturnsFailure() {
        let resolution = IntentResolver.resolveSong(title: "Nonexistent Track", artist: nil, songs: [
            .init(trackId: 1, title: "Hotel California", artist: "Eagles")
        ])

        #expect(resolution == .failure(.noMatch(kind: .song, query: "Nonexistent Track")))
    }

    @Test func testResumeAlwaysReturnsCommand() {
        #expect(IntentResolver.resolveResume() == .command(.resume))
    }

    @Test func testAddSourceAcceptsArchiveURL() {
        let raw = " https://archive.org/details/foo "
        let resolution = IntentResolver.resolveAddSource(rawURL: raw)

        #expect(resolution == .command(.addSource(rawURL: "https://archive.org/details/foo")))
    }

    @Test func testAddSourceRejectsForeignURL() {
        let resolution = IntentResolver.resolveAddSource(rawURL: "https://example.com/details/foo")

        #expect(resolution == .failure(.malformedURL("https://example.com/details/foo")))
    }

    @Test func testSleepTimerBounds() {
        #expect(
            IntentResolver.resolveSleepTimer(minutes: IntentResolver.minimumSleepMinutes) ==
            .command(.setSleepTimer(.minutes(IntentResolver.minimumSleepMinutes)))
        )
        #expect(
            IntentResolver.resolveSleepTimer(minutes: IntentResolver.maximumSleepMinutes) ==
            .command(.setSleepTimer(.minutes(IntentResolver.maximumSleepMinutes)))
        )
        #expect(
            IntentResolver.resolveSleepTimer(minutes: 0) ==
            .failure(.invalidSleepTimerMinutes(0))
        )
        #expect(
            IntentResolver.resolveSleepTimer(minutes: IntentResolver.maximumSleepMinutes + 1) ==
            .failure(.invalidSleepTimerMinutes(IntentResolver.maximumSleepMinutes + 1))
        )
    }
}
