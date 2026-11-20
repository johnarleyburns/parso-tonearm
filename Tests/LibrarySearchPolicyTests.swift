import Testing
@testable import TonearmCore

@Suite struct LibrarySearchPolicyTests {
    @Test func testWhitespaceDoesNotStartDatabaseSearch() {
        #expect(!LibrarySearchPolicy.shouldSearch("  \n\t"))
        #expect(LibrarySearchPolicy.shouldSearch("ambient"))
    }
}
