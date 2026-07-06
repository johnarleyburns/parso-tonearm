import XCTest
@testable import Tonearm

/// TF2: list & collection resolution must work; these lock down the member
/// parsing that previously errored.
final class ListResolverTests: XCTestCase {

    func testParsesMembersArrayShape() {
        let json = """
        {"members":[{"identifier":"item-a","title":"A"},{"identifier":"item-b","title":"B"}]}
        """.data(using: .utf8)!
        let members = ListResolver.parseMembers(from: json)
        XCTAssertEqual(members.map(\.identifier), ["item-a", "item-b"])
        XCTAssertEqual(members.first?.title, "A")
    }

    func testParsesIdsShape() {
        let json = #"{"ids":["one","two","three"]}"#.data(using: .utf8)!
        let members = ListResolver.parseMembers(from: json)
        XCTAssertEqual(members.map(\.identifier), ["one", "two", "three"])
    }

    func testParsesMembersDictionaryShape() {
        let json = """
        {"members":{"beta":{"title":"Beta"},"alpha":{"title":"Alpha"}}}
        """.data(using: .utf8)!
        let members = ListResolver.parseMembers(from: json)
        // Dictionary keys are sorted for determinism.
        XCTAssertEqual(members.map(\.identifier), ["alpha", "beta"])
        XCTAssertEqual(members.first?.title, "Alpha")
    }

    func testEmptyOnGarbage() {
        XCTAssertTrue(ListResolver.parseMembers(from: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(ListResolver.parseMembers(from: Data("{}".utf8)).isEmpty)
    }

    func testHTMLDetailExtractionDeduplicatesAndFilters() {
        let html = """
        <a href="/details/goldberg-variations">x</a>
        <a href="/details/goldberg-variations">dup</a>
        <a href="/details/@someuser/lists/123">list</a>
        <a href="/details/fav-someuser">fav</a>
        <a href="/details/well-tempered-clavier">y</a>
        """
        let members = ListResolver.extractDetailIdentifiers(from: html)
        XCTAssertEqual(members.map(\.identifier), ["goldberg-variations", "well-tempered-clavier"])
    }

    func testCollectionPageDecodesAudioMembers() throws {
        let json = """
        {"items":[
          {"identifier":"aud1","title":"One","mediatype":"audio"},
          {"identifier":"vid1","title":"Two","mediatype":"movies"},
          {"identifier":"etr1","title":"Three","mediatype":"etree"}
        ],"total":3,"cursor":null}
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(CollectionResolver.Page.self, from: json)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.items?.count, 3)
    }
}
