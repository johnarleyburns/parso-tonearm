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

    func testFindModeButtonsUseByLabels() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/MyMusic/MyMusicSearchControls.swift"),
                           encoding: .utf8)
        XCTAssertTrue(s.contains("case all = \"By Name\""))
        XCTAssertTrue(s.contains("case sound = \"By Mood\""))
        XCTAssertTrue(s.contains("case mix = \"By BPM/Key\""))
        XCTAssertFalse(s.contains("case all = \"All\""))
        XCTAssertFalse(s.contains("Find Mood"))
        XCTAssertFalse(s.contains("Find Mix"))
        XCTAssertFalse(s.contains("Find by BPM/Key"))
        XCTAssertTrue(s.contains("find.mode.\\(option == .all ? \"all\" : option == .sound ? \"mood\" : \"mix\")"),
                      "find.mode.all/mood/mix identifiers must stay unchanged")
    }
}
#endif
