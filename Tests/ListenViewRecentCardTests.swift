import XCTest

/// Real report: Jump Back In / Favorites card titles truncated to one line. Both sections render
/// through the same shared `RecentCard` (`ListenView.swift`) — one fix covers both. Source
/// inspection (no simulator), matching this repo's established convention.
final class ListenViewRecentCardTests: XCTestCase {
    private func listenViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
            encoding: .utf8)
    }

    func testRecentCardTitleAllowsTwoLines() throws {
        let source = try listenViewSource()
        let declRange = try XCTUnwrap(source.range(of: "struct RecentCard: View {"))
        let titleRange = try XCTUnwrap(source.range(of: "Text(row.track.title)", range: declRange.lowerBound..<source.endIndex))
        let closeRange = try XCTUnwrap(source.range(of: ".padding(.top, 7)", range: titleRange.upperBound..<source.endIndex))
        let titleBlock = source[titleRange.upperBound..<closeRange.upperBound]
        XCTAssertTrue(titleBlock.contains(".lineLimit(2)"),
            "RecentCard's title must allow two lines instead of truncating to one")
        XCTAssertFalse(titleBlock.contains(".lineLimit(1)"))
    }

    /// Both "Jump Back In" and "Favorites" render through the same `cardRow`/`RecentCard`, so the
    /// shared fixed-height container must grow to fit the extra title line without clipping.
    func testCollectionContentHeightGrewForTwoLineTitles() throws {
        let source = try listenViewSource()
        XCTAssertTrue(source.contains("private var collectionContentHeight: CGFloat = 206"),
            "collectionContentHeight must be increased from its old 188 to fit a two-line title")
    }
}
