import XCTest
@testable import Tonearm

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
