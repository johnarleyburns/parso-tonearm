import XCTest

/// Real reports: Libraries > On This Device should not show "Mood Starter" (a removed feature's
/// leftover local-row data on upgraded installs) or "Built-in Sounds" (bundled app content, not
/// a real local folder), and its own "+ Add Local Folder" row duplicates the + menu's entry of
/// the same name. Source inspection (no simulator), matching this repo's established convention.
final class SourcesViewOnThisDeviceTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Sources/SourcesView.swift"),
            encoding: .utf8)
    }

    func testLocalSourcesHidesBuiltInAndMoodStarter() throws {
        let text = try source()
        XCTAssertTrue(text.contains("hiddenLocalSourceTitles"))
        XCTAssertTrue(text.contains("\"Built-in Sounds\""))
        XCTAssertTrue(text.contains("\"Mood Starter\""))
        let declRange = try XCTUnwrap(text.range(of: "private var localSources: [Source] {"))
        let closeRange = try XCTUnwrap(text.range(of: "\n    }", range: declRange.upperBound..<text.endIndex))
        let body = text[declRange.upperBound..<closeRange.lowerBound]
        XCTAssertTrue(body.contains("hiddenLocalSourceTitles"),
            "localSources must filter out the hidden titles, not just declare the set")
    }

    func testAddLocalFolderRowRemoved() throws {
        let text = try source()
        XCTAssertFalse(text.contains("\"Add Local Folder Row\""),
            "the duplicate + Add Local Folder row inside On This Device must be removed")
        XCTAssertFalse(text.contains("Text(\"Add Local Folder\")"))
    }
}
