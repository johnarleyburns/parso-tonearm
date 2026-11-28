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

    @Test func testExplicitEmptyResultSetIsNotUnfilteredBrowsing() {
        // An explicit result set (possibly empty) is a real query outcome, not an unfiltered
        // browse, even when the text field itself is empty.
        #expect(!LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "", searchRows: [], filter: MyMusicFilter()))
    }

    @Test func testBPMKeyFilterWithNoMatchesIsNotUnfilteredBrowsing() {
        let filter = MyMusicFilter(mixKey: "8A")
        #expect(!LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "", searchRows: nil, filter: filter))
    }
}
