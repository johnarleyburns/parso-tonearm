import Testing
@testable import TonearmWatchCore

@Suite struct WatchPlaylistNameMatchTests {
    private let titles = ["Morning Run", "Deep Focus", "Late Night Jazz"]

    @Test func testExactMatchIsCaseInsensitive() {
        #expect(WatchPlaylistNameMatch.best("deep focus", in: titles) == "Deep Focus")
    }

    @Test func testPrefixMatch() {
        #expect(WatchPlaylistNameMatch.best("morning", in: titles) == "Morning Run")
    }

    @Test func testSubstringMatch() {
        #expect(WatchPlaylistNameMatch.best("jazz", in: titles) == "Late Night Jazz")
    }

    @Test func testReverseMatchWhenQueryIsWordier() {
        #expect(WatchPlaylistNameMatch.best("play my deep focus playlist", in: titles) == "Deep Focus")
    }

    @Test func testNoMatchReturnsNil() {
        #expect(WatchPlaylistNameMatch.best("workout", in: titles) == nil)
    }

    @Test func testEmptyInputsReturnNil() {
        #expect(WatchPlaylistNameMatch.best("", in: titles) == nil)
        #expect(WatchPlaylistNameMatch.best("   ", in: titles) == nil)
        #expect(WatchPlaylistNameMatch.best("anything", in: []) == nil)
    }
}
