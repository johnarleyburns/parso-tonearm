import Foundation
import Testing

/// Real report: Jump Back In / Favorites card titles truncated to one line. Both sections render
/// through the same shared `RecentCard` (`ListenView.swift`) — one fix covers both. Source
/// inspection (no simulator), matching this repo's established convention.
@Suite struct ListenViewRecentCardTests {
    private func listenViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
            encoding: .utf8)
    }

    @Test func testRecentCardTitleAllowsTwoLines() throws {
        let source = try listenViewSource()
        let declRange = try #require(source.range(of: "struct RecentCard: View {"))
        let titleRange = try #require(source.range(of: "Text(row.track.title)", range: declRange.lowerBound..<source.endIndex))
        let closeRange = try #require(source.range(of: ".padding(.top, 7)", range: titleRange.upperBound..<source.endIndex))
        let titleBlock = source[titleRange.upperBound..<closeRange.upperBound]
        #expect(titleBlock.contains(".lineLimit(2)"),
            "RecentCard's title must allow two lines instead of truncating to one")
        #expect(!titleBlock.contains(".lineLimit(1)"))
    }

    /// Both "Jump Back In" and "Favorites" render through the same `cardRow`/`RecentCard`, so the
    /// shared fixed-height container must grow to fit the extra title line without clipping.
    @Test func testCollectionContentHeightGrewForTwoLineTitles() throws {
        let source = try listenViewSource()
        #expect(source.contains("private var collectionContentHeight: CGFloat = 206"),
            "collectionContentHeight must be increased from its old 188 to fit a two-line title")
    }
}
