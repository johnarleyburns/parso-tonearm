import XCTest

/// Real report: with one Google Drive track playing and 1,000+ library tracks,
/// Keep Playing added nothing and said "Shuffled · no compatible recommendation
/// was available" — dead air. The source-scoped fallback pool only had that one
/// (already-excluded) track, so it must broaden to the library before giving up.
final class KeepPlayingFallbackBreadthTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testFallbackBroadensToLibraryWhenScopedPoolIsEmpty() throws {
        let text = try source("Sources/Audio/AudioPlayer+KeepPlaying.swift")
        let start = try XCTUnwrap(text.range(of: "private func extendWithFallback"))
        let end = try XCTUnwrap(text.range(of: "private func keepPlayingFallbackPool"))
        let block = text[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(block.contains("if candidates.isEmpty {"))
        XCTAssertTrue(block.contains("LibraryStore.shared.allTrackRows()"),
                      "an exhausted source-scoped pool must broaden to the library, never dead air")
        XCTAssertTrue(block.contains("excluded.contains(id)") || block.contains("!excluded.contains(id)"),
                      "the broadened pool must still honor the exclusions")
    }

    /// Queue header: an icon replaces the "From Library:" text prefix.
    func testQueueHeaderUsesSourceIconAndShortSectionLabel() throws {
        let queueSource = try source("Sources/Audio/AudioPlayer+QueueSource.swift")
        XCTAssertTrue(queueSource.contains("public var icon: String"))
        XCTAssertTrue(queueSource.contains("public var shortLabel: String"))
        XCTAssertTrue(queueSource.contains("case .source: return \"externaldrive.connected.to.line.below\""))

        let upNext = try source("Sources/Features/NowPlaying/UpNextView.swift")
        XCTAssertFalse(upNext.contains("Text(player.queueSource.label)"),
                       "the queue header must not print 'From Library: …'")
        XCTAssertTrue(upNext.contains("Image(systemName: player.queueSource.icon)"))
        XCTAssertTrue(upNext.contains("Playing from \\(player.queueSource.shortLabel)"))
    }
}
