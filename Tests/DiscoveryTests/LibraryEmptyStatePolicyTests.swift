import Testing
@testable import TonearmCore
@testable import TonearmDiscovery

@Suite struct LibraryEmptyStatePolicyTests {
    @Test func testTrulyEmptyLibraryIsUnfilteredBrowsing() {
        #expect(LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "", searchRows: nil, filter: MyMusicFilter()))
        #expect(LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "   ", searchRows: nil, filter: MyMusicFilter()))
    }

    @Test func testActiveTextSearchIsNotUnfilteredBrowsing() {
        #expect(!LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "lofi", searchRows: nil, filter: MyMusicFilter()))
    }

    @Test func testMoodSearchWithNoMatchesIsNotUnfilteredBrowsing() {
        // Find's Mood mode: searchText is often empty (the query came from mood pills), but
        // `searchRows` is a non-nil (possibly empty) array once a search actually ran.
        #expect(!LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "", searchRows: [], filter: MyMusicFilter()))
    }

    @Test func testBPMKeyFilterWithNoMatchesIsNotUnfilteredBrowsing() {
        let filter = MyMusicFilter(mixKey: "8A")
        #expect(!LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "", searchRows: nil, filter: filter))
    }
}
