#if !os(watchOS)
import XCTest

/// Find uses the native large navigation title and keeps its result identifiers.
final class FindNativeTitleContractTests: XCTestCase {
    func testFindUsesNativeLargeTitle() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                           encoding: .utf8)
        XCTAssertFalse(s.contains("ScreenHeader("), "custom Find header must be gone")
        XCTAssertFalse(s.contains("hiddenNavigationBar"), "Find root must not hide its bar")
        XCTAssertTrue(s.contains(".navigationTitle(\"Find\")"))
        XCTAssertTrue(s.contains(".largeNavigationTitle()"))
        XCTAssertTrue(s.contains("\"find.results\""))
        XCTAssertTrue(s.contains("\"find.awaitingQuery\""))
    }
}
#endif
