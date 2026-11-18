import Testing

/// Jump Back In / Favorites share `cardRow`; it must realize cards lazily (bounded rendering)
/// while keeping stable identity, interactions and the fixed collection height.
@Suite struct ListenCardRowLazyRenderingTests {
    private func cardRowBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "private func cardRow("))
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "/// Runs only from the confirmed destructive dialog action."))
        return String(rest[..<end.lowerBound])
    }

    @Test func testCardRowUsesLazyHStack() throws {
        let body = try cardRowBody()
        #expect(body.contains("LazyHStack(spacing: 12)"), "cardRow must realize cards lazily")
        #expect(!body.contains(" HStack(spacing: 12)"), "cardRow must not use an eager HStack")
    }

    @Test func testCardRowKeepsIdentityInteractionsAndHeight() throws {
        let body = try cardRowBody()
        #expect(body.contains("ForEach(rows)"), "stable TrackRow identity")
        #expect(body.contains("selectedTrackForDetail = row"))
        #expect(body.contains(".trackContextMenu(row, showRemoveFromJumpBackIn: identifier == \"listen.recent\""))
        #expect(body.contains(".frame(height: collectionContentHeight"))
        #expect(body.contains(".accessibilityIdentifier(identifier)"))
    }
}
