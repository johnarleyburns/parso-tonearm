import XCTest
@testable import Tonearm

final class ShareURLBuilderTests: XCTestCase {

    func testSimpleIdentifier() {
        let url = ShareURLBuilder.url(identifier: "GratefulDead1977")
        XCTAssertEqual(url?.absoluteString, "https://archive.org/details/GratefulDead1977")
    }

    func testFavoritesStripsPrefix() {
        let url = ShareURLBuilder.url(identifier: "fav-jsmith")
        XCTAssertEqual(url?.absoluteString, "https://archive.org/details/jsmith")
    }

    func testEmptyIdentifierReturnsNil() {
        XCTAssertNil(ShareURLBuilder.url(identifier: ""))
    }

    func testIdentifierWithSlashes() {
        let url = ShareURLBuilder.url(identifier: "some_collection/item_name")
        XCTAssertEqual(url?.absoluteString, "https://archive.org/details/some_collection/item_name")
    }
}
