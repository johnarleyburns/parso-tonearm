import XCTest
@testable import TonearmCore

final class ListResolverScrapeTests: XCTestCase {

    func testParseMembersShapeA() {
        let json = """
        {"members":[{"identifier":"item1","title":"Title 1"},{"identifier":"item2","title":"Title 2"}]}
        """
        let data = Data(json.utf8)
        let result = ListResolver.parseMembers(from: data)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].identifier, "item1")
        XCTAssertEqual(result[0].title, "Title 1")
        XCTAssertEqual(result[1].identifier, "item2")
    }

    func testParseMembersShapeB() {
        let json = """
        {"ids":["item_a","item_b","item_c"]}
        """
        let data = Data(json.utf8)
        let result = ListResolver.parseMembers(from: data)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.identifier), ["item_a", "item_b", "item_c"])
    }

    func testParseMembersShapeC() {
        let json = """
        {"members":{"item_x":{"title":"X Title"},"item_y":{"title":"Y Title"}}}
        """
        let data = Data(json.utf8)
        let result = ListResolver.parseMembers(from: data)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains(where: { $0.identifier == "item_x" && $0.title == "X Title" }))
        XCTAssertTrue(result.contains(where: { $0.identifier == "item_y" && $0.title == "Y Title" }))
    }

    func testParseMembersEmptyJSON() {
        let data = Data("{}".utf8)
        let result = ListResolver.parseMembers(from: data)
        XCTAssertTrue(result.isEmpty)
    }

    func testExtractDetailIdentifiers() {
        let html = """
        <a href="/details/some_item">link1</a>
        <a href="/details/another_item">link2</a>
        <a href="/details/item_with-dots_1">link3</a>
        """
        let result = ListResolver.extractDetailIdentifiers(from: html)
        let ids = result.map(\.identifier)
        XCTAssertTrue(ids.contains("some_item"))
        XCTAssertTrue(ids.contains("another_item"))
        XCTAssertTrue(ids.contains("item_with-dots_1"))
    }

    func testExtractDetailIdentifiersExcludesUserPrefix() {
        let html = """
        <a href="/details/some_item">good</a>
        <a href="/details/@johndoe/lists/2">bad</a>
        """
        let result = ListResolver.extractDetailIdentifiers(from: html)
        let ids = result.map(\.identifier)
        XCTAssertTrue(ids.contains("some_item"))
        XCTAssertFalse(ids.contains("@johndoe/lists/2"))
    }

    func testExtractDetailIdentifiersExcludesFavPrefix() {
        let html = """
        <a href="/details/some_item">good</a>
        <a href="/details/fav-jsmith">bad</a>
        """
        let result = ListResolver.extractDetailIdentifiers(from: html)
        let ids = result.map(\.identifier)
        XCTAssertTrue(ids.contains("some_item"))
        XCTAssertFalse(ids.contains("fav-jsmith"))
    }

    func testParseUsersListResponse() {
        let json = """
        {"success":true,"value":{"list_name":"Test","members":[{"identifier":"item-a"},{"identifier":"item-b"}]}}
        """
        let data = Data(json.utf8)
        let result = ListResolver.parseMembers(from: data)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].identifier, "item-a")
        XCTAssertEqual(result[1].identifier, "item-b")
    }
}
