import Testing
@testable import TonearmCore

@Suite struct ListResolverScrapeTests {

    @Test func testParseMembersShapeA() {
        let json = """
        {"members":[{"identifier":"item1","title":"Title 1"},{"identifier":"item2","title":"Title 2"}]}
        """
        let data = Data(json.utf8)
        let result = ListResolver.parseMembers(from: data)
        #expect(result.count == 2)
        #expect(result[0].identifier == "item1")
        #expect(result[0].title == "Title 1")
        #expect(result[1].identifier == "item2")
    }

    @Test func testParseMembersShapeB() {
        let json = """
        {"ids":["item_a","item_b","item_c"]}
        """
        let data = Data(json.utf8)
        let result = ListResolver.parseMembers(from: data)
        #expect(result.count == 3)
        #expect(result.map(\.identifier) == ["item_a", "item_b", "item_c"])
    }

    @Test func testParseMembersShapeC() {
        let json = """
        {"members":{"item_x":{"title":"X Title"},"item_y":{"title":"Y Title"}}}
        """
        let data = Data(json.utf8)
        let result = ListResolver.parseMembers(from: data)
        #expect(result.count == 2)
        #expect(result.contains(where: { $0.identifier == "item_x" && $0.title == "X Title" }))
        #expect(result.contains(where: { $0.identifier == "item_y" && $0.title == "Y Title" }))
    }

    @Test func testParseMembersEmptyJSON() {
        let data = Data("{}".utf8)
        let result = ListResolver.parseMembers(from: data)
        #expect(result.isEmpty)
    }

    @Test func testExtractDetailIdentifiers() {
        let html = """
        <a href="/details/some_item">link1</a>
        <a href="/details/another_item">link2</a>
        <a href="/details/item_with-dots_1">link3</a>
        """
        let result = ListResolver.extractDetailIdentifiers(from: html)
        let ids = result.map(\.identifier)
        #expect(ids.contains("some_item"))
        #expect(ids.contains("another_item"))
        #expect(ids.contains("item_with-dots_1"))
    }

    @Test func testExtractDetailIdentifiersExcludesUserPrefix() {
        let html = """
        <a href="/details/some_item">good</a>
        <a href="/details/@johndoe/lists/2">bad</a>
        """
        let result = ListResolver.extractDetailIdentifiers(from: html)
        let ids = result.map(\.identifier)
        #expect(ids.contains("some_item"))
        #expect(!ids.contains("@johndoe/lists/2"))
    }

    @Test func testExtractDetailIdentifiersExcludesFavPrefix() {
        let html = """
        <a href="/details/some_item">good</a>
        <a href="/details/fav-jsmith">bad</a>
        """
        let result = ListResolver.extractDetailIdentifiers(from: html)
        let ids = result.map(\.identifier)
        #expect(ids.contains("some_item"))
        #expect(!ids.contains("fav-jsmith"))
    }

    @Test func testParseUsersListResponse() {
        let json = """
        {"success":true,"value":{"list_name":"Test","members":[{"identifier":"item-a"},{"identifier":"item-b"}]}}
        """
        let data = Data(json.utf8)
        let result = ListResolver.parseMembers(from: data)
        #expect(result.count == 2)
        #expect(result[0].identifier == "item-a")
        #expect(result[1].identifier == "item-b")
    }
}
