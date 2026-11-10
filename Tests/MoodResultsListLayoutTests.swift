import XCTest

/// Mood results render as a vertical one-row-per-track list (`TrackRowView`), not a horizontal
/// `RecentCard` carousel. Tap behavior (detail sheet + context menu) is unchanged.
final class MoodResultsListLayoutTests: XCTestCase {
    private func moodResultsRowBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var moodResultsRow: some View {"))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\nprivate struct DisplayOrderKey")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    func testMoodResultsUseVerticalTrackRowList() throws {
        let body = try moodResultsRowBody()
        XCTAssertTrue(body.contains("TrackRowView"), "moodResultsRow must render TrackRowView rows")
        XCTAssertFalse(body.contains("RecentCard"), "moodResultsRow must not use RecentCard")
        XCTAssertFalse(body.contains("ScrollView(.horizontal"), "moodResultsRow must not scroll horizontally")
    }

    func testMoodRowTapAndContextMenuUnchanged() throws {
        let body = try moodResultsRowBody()
        XCTAssertTrue(body.contains("selectedTrackForDetail = result.track"))
        XCTAssertTrue(body.contains(".trackContextMenu(result.track)"))
        XCTAssertFalse(body.contains("player.play"), "rows must not gain tap-to-play")
    }
}
