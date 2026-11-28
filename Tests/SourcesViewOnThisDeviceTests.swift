import Foundation
import Testing

/// Real reports: Libraries > On This Device should not show "Built-in Sounds" (bundled app
/// content, not a real local folder), and its own "+ Add Local Folder" row duplicates the +
/// menu's entry of the same name. Source inspection (no simulator), matching this repo's
/// established convention.
@Suite struct SourcesViewOnThisDeviceTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Sources/SourcesView.swift"),
            encoding: .utf8)
    }

    @Test func testLocalSourcesHidesBuiltInContent() throws {
        let text = try source()
        #expect(text.contains("hiddenLocalSourceTitles"))
        #expect(text.contains("\"Built-in Sounds\""))
        let declRange = try #require(text.range(of: "private var localSources: [Source] {"))
        let closeRange = try #require(text.range(of: "\n    }", range: declRange.upperBound..<text.endIndex))
        let body = text[declRange.upperBound..<closeRange.lowerBound]
        #expect(body.contains("hiddenLocalSourceTitles"),
            "localSources must filter out the hidden titles, not just declare the set")
    }

    @Test func testAddLocalFolderRowRemoved() throws {
        let text = try source()
        #expect(!text.contains("\"Add Local Folder Row\""),
            "the duplicate + Add Local Folder row inside On This Device must be removed")
        #expect(!text.contains("Text(\"Add Local Folder\")"))
    }
}
