#if !os(watchOS)
import XCTest

/// Find Mood reuses the single top search field instead of owning a second one.
final class MyMusicSearchControlsContractTests: XCTestCase {
    private func source() throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent("Sources/Features/MyMusic/MyMusicSearchControls.swift"),
                          encoding: .utf8)
    }

    func testSoundQueryOwnsNoTextField() throws {
        let s = try source()
        let tail = try XCTUnwrap(s.range(of: "struct MyMusicSoundQuery")).lowerBound
        XCTAssertFalse(String(s[tail...]).contains("TextField("))
        XCTAssertFalse(s.contains("TextField("))
    }

    func testTopFieldStaysVisibleInFindMood() throws {
        let s = try source()
        XCTAssertFalse(s.contains("if mode == .all { allSearchField }"))
        XCTAssertTrue(s.contains("if mode != .mix { allSearchField }"))
        XCTAssertFalse(s.contains("if newMode != .all { appState.searchText = \"\" }"))
    }

    func testTopFieldDrivesSoundModel() throws {
        let s = try source()
        XCTAssertTrue(s.contains(".onChange(of: appState.searchText)"))
        XCTAssertTrue(s.contains("soundModel.searchText = text"))
    }
}
#endif
