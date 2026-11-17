import XCTest
@testable import TonearmCore
@testable import TonearmDiscovery

final class LibraryEmptyStatePolicyTests: XCTestCase {
    func testTrulyEmptyLibraryIsUnfilteredBrowsing() {
        XCTAssertTrue(LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "", searchRows: nil, filter: MyMusicFilter()))
        XCTAssertTrue(LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "   ", searchRows: nil, filter: MyMusicFilter()))
    }

    func testActiveTextSearchIsNotUnfilteredBrowsing() {
        XCTAssertFalse(LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "lofi", searchRows: nil, filter: MyMusicFilter()))
    }

    func testMoodSearchWithNoMatchesIsNotUnfilteredBrowsing() {
        // Find's Mood mode: searchText is often empty (the query came from mood pills), but
        // `searchRows` is a non-nil (possibly empty) array once a search actually ran.
        XCTAssertFalse(LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "", searchRows: [], filter: MyMusicFilter()))
    }

    func testBPMKeyFilterWithNoMatchesIsNotUnfilteredBrowsing() {
        let filter = MyMusicFilter(mixKey: "8A")
        XCTAssertFalse(LibraryEmptyStatePolicy.isUnfilteredBrowsing(
            searchText: "", searchRows: nil, filter: filter))
    }
}
