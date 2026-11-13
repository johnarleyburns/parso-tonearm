import XCTest

/// Jump Back In / Favorites share `cardRow`; it must realize cards lazily (bounded rendering)
/// while keeping stable identity, interactions and the fixed collection height.
final class ListenCardRowLazyRenderingTests: XCTestCase {
    private func cardRowBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func cardRow("))
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "/// Runs only from the confirmed destructive dialog action."))
        return String(rest[..<end.lowerBound])
    }

    func testCardRowUsesLazyHStack() throws {
        let body = try cardRowBody()
        XCTAssertTrue(body.contains("LazyHStack(spacing: 12)"), "cardRow must realize cards lazily")
        XCTAssertFalse(body.contains(" HStack(spacing: 12)"), "cardRow must not use an eager HStack")
    }

    func testCardRowKeepsIdentityInteractionsAndHeight() throws {
        let body = try cardRowBody()
        XCTAssertTrue(body.contains("ForEach(rows)"), "stable TrackRow identity")
        XCTAssertTrue(body.contains("selectedTrackForDetail = row"))
        XCTAssertTrue(body.contains(".trackContextMenu(row, showRemoveFromJumpBackIn: identifier == \"listen.recent\""))
        XCTAssertTrue(body.contains(".frame(height: collectionContentHeight"))
        XCTAssertTrue(body.contains(".accessibilityIdentifier(identifier)"))
    }
}
