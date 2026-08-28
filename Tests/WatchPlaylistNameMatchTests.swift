import XCTest
@testable import TonearmWatchCore

final class WatchPlaylistNameMatchTests: XCTestCase {
    private let titles = ["Morning Run", "Deep Focus", "Late Night Jazz"]

    func testExactMatchIsCaseInsensitive() {
        XCTAssertEqual(WatchPlaylistNameMatch.best("deep focus", in: titles), "Deep Focus")
    }

    func testPrefixMatch() {
        XCTAssertEqual(WatchPlaylistNameMatch.best("morning", in: titles), "Morning Run")
    }

    func testSubstringMatch() {
        XCTAssertEqual(WatchPlaylistNameMatch.best("jazz", in: titles), "Late Night Jazz")
    }

    func testReverseMatchWhenQueryIsWordier() {
        XCTAssertEqual(WatchPlaylistNameMatch.best("play my deep focus playlist", in: titles), "Deep Focus")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(WatchPlaylistNameMatch.best("workout", in: titles))
    }

    func testEmptyInputsReturnNil() {
        XCTAssertNil(WatchPlaylistNameMatch.best("", in: titles))
        XCTAssertNil(WatchPlaylistNameMatch.best("   ", in: titles))
        XCTAssertNil(WatchPlaylistNameMatch.best("anything", in: []))
    }
}
