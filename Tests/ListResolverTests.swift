import Foundation
import Testing
@testable import TonearmCore

/// TF2: list & collection resolution must work; these lock down the member
/// parsing that previously errored.
@Suite struct ListResolverTests {

    @Test func testParsesMembersArrayShape() {
        let json = """
        {"members":[{"identifier":"item-a","title":"A"},{"identifier":"item-b","title":"B"}]}
        """.data(using: .utf8)!
        let members = ListResolver.parseMembers(from: json)
        #expect(members.map(\.identifier) == ["item-a", "item-b"])
        #expect(members.first?.title == "A")
    }

    @Test func testParsesIdsShape() {
        let json = #"{"ids":["one","two","three"]}"#.data(using: .utf8)!
        let members = ListResolver.parseMembers(from: json)
        #expect(members.map(\.identifier) == ["one", "two", "three"])
    }

    @Test func testParsesMembersDictionaryShape() {
        let json = """
        {"members":{"beta":{"title":"Beta"},"alpha":{"title":"Alpha"}}}
        """.data(using: .utf8)!
        let members = ListResolver.parseMembers(from: json)
        // Dictionary keys are sorted for determinism.
        #expect(members.map(\.identifier) == ["alpha", "beta"])
        #expect(members.first?.title == "Alpha")
    }

    @Test func testEmptyOnGarbage() {
        #expect(ListResolver.parseMembers(from: Data("not json".utf8)).isEmpty)
        #expect(ListResolver.parseMembers(from: Data("{}".utf8)).isEmpty)
    }

    @Test func testHTMLDetailExtractionDeduplicatesAndFilters() {
        let html = """
        <a href="/details/goldberg-variations">x</a>
        <a href="/details/goldberg-variations">dup</a>
        <a href="/details/@someuser/lists/123">list</a>
        <a href="/details/fav-someuser">fav</a>
        <a href="/details/well-tempered-clavier">y</a>
        """
        let members = ListResolver.extractDetailIdentifiers(from: html)
        #expect(members.map(\.identifier) == ["goldberg-variations", "well-tempered-clavier"])
    }

    @Test func testCollectionPageDecodesAudioMembers() throws {
        let json = """
        {"items":[
          {"identifier":"aud1","title":"One","mediatype":"audio"},
          {"identifier":"vid1","title":"Two","mediatype":"movies"},
          {"identifier":"etr1","title":"Three","mediatype":"etree"}
        ],"total":3,"cursor":null}
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(CollectionResolver.Page.self, from: json)
        #expect(page.total == 3)
        #expect(page.items?.count == 3)
    }

    @Test func testParsesCurrentUserListsShape() {
        let json = """
        {"success":true,"value":[
          {"id":1,"list_name":"One","members":[{"identifier":"item-a"},{"identifier":"item-b"}]},
          {"id":2,"list_name":"Two","members":[{"identifier":"item-c"}]}
        ]}
        """.data(using: .utf8)!
        let members = ListResolver.parseMembers(from: json)
        #expect(members.map(\.identifier) == ["item-a", "item-b", "item-c"])
    }
}
