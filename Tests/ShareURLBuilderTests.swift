import Testing
@testable import TonearmCore

@Suite struct ShareURLBuilderTests {

    @Test func testSimpleIdentifier() {
        let url = ShareURLBuilder.url(identifier: "GratefulDead1977")
        #expect(url?.absoluteString == "https://archive.org/details/GratefulDead1977")
    }

    @Test func testFavoritesStripsPrefix() {
        let url = ShareURLBuilder.url(identifier: "fav-jsmith")
        #expect(url?.absoluteString == "https://archive.org/details/jsmith")
    }

    @Test func testEmptyIdentifierReturnsNil() {
        #expect(ShareURLBuilder.url(identifier: "") == nil)
    }

    @Test func testIdentifierWithSlashes() {
        let url = ShareURLBuilder.url(identifier: "some_collection/item_name")
        #expect(url?.absoluteString == "https://archive.org/details/some_collection/item_name")
    }
}
