import Foundation
import Testing

/// Real report: with one Google Drive track playing and 1,000+ library tracks,
/// Keep Playing added nothing and said "Shuffled · no compatible recommendation
/// was available" — dead air. The source-scoped fallback pool only had that one
/// (already-excluded) track, so it must broaden to the library before giving up.
@Suite struct KeepPlayingFallbackBreadthTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func testFallbackBroadensToLibraryWhenScopedPoolIsEmpty() throws {
        let text = try source("Sources/Audio/AudioPlayer+KeepPlaying.swift")
        let start = try #require(text.range(of: "private func extendWithFallback"))
        let end = try #require(text.range(of: "private func keepPlayingFallbackPool"))
        let block = text[start.lowerBound..<end.lowerBound]

        #expect(block.contains("if candidates.isEmpty {"))
        #expect(block.contains("keepPlayingLibrary.allTrackRows()"),
                "an exhausted source-scoped pool must broaden to the library, never dead air")
        #expect(block.contains("excluded.contains(id)") || block.contains("!excluded.contains(id)"),
                "the broadened pool must still honor the exclusions")
    }

    /// Queue header: an icon replaces the "From Library:" text prefix.
    @Test func testQueueHeaderUsesSourceIconAndShortSectionLabel() throws {
        let queueSource = try source("Sources/Audio/AudioPlayer+QueueSource.swift")
        #expect(queueSource.contains("public var icon: String"))
        #expect(queueSource.contains("public var shortLabel: String"))
        #expect(queueSource.contains("case .source: return \"externaldrive.connected.to.line.below\""))

        let upNext = try source("Sources/Features/NowPlaying/UpNextView.swift")
        #expect(!upNext.contains("Text(player.queueSource.label)"),
                "the queue header must not print 'From Library: …'")
        #expect(upNext.contains("Image(systemName: player.queueSource.icon)"))
        #expect(upNext.contains("Playing from \\(player.queueSource.shortLabel)"))
    }
}
