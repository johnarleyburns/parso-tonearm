import XCTest
@testable import TonearmCore

final class LibrarySearchPolicyTests: XCTestCase {
    func testWhitespaceDoesNotStartDatabaseSearch() {
        XCTAssertFalse(LibrarySearchPolicy.shouldSearch("  \n\t"))
        XCTAssertTrue(LibrarySearchPolicy.shouldSearch("ambient"))
    }
}
