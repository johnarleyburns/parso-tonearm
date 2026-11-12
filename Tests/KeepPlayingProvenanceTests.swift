import XCTest
@testable import TonearmCore

@MainActor
final class KeepPlayingProvenanceTests: XCTestCase {
    nonisolated static func row(trackId: Int64) -> TrackRow {
        TrackRow(
            track: Track(id: trackId, albumId: nil, sourceId: 1,
                         title: "T\(trackId)", trackNo: 1, discNo: nil,
                         durationSec: 200, codec: "MP3", sampleRate: nil,
                         bitDepthOrBitrate: nil, sortKey: "T\(trackId)"),
            album: nil, source: nil, asset: nil)
    }

    private func entry(_ id: Int64, _ reason: KeepPlayingRecommendationReason,
                       bpm: Double? = nil, key: String? = nil) -> PlaybackQueueEntry {
        PlaybackQueueEntry(row: Self.row(trackId: id), origin: .keepPlaying(reason),
                           mixBPM: bpm, mixCamelotKey: key)
    }

    func testMixMatchedSubtitle() throws {
        let e = entry(1, .mixMatched, bpm: 124.4, key: "9A")
        XCTAssertEqual(e.provenance?.subtitle, "Mix match · 124.4 BPM · 9A")
        XCTAssertEqual(KeepPlayingProvenance(reason: .mixMatched, bpm: 124, camelotKey: "9A")?.subtitle,
                       "Mix match · 124 BPM · 9A")
    }

    func testOtherReasonSubtitles() {
        XCTAssertEqual(entry(1, .soundSimilar).provenance?.subtitle, "Sound similar · no BPM/key match available")
        XCTAssertEqual(entry(1, .modelUnavailableShuffle).provenance?.subtitle, "Shuffled · sound model is not ready")
        XCTAssertEqual(entry(1, .noMatchShuffle).provenance?.subtitle,
                       "Shuffled · no compatible recommendation was available")
    }

    func testMixedTailHasDistinctSubtitles() {
        let subs = [entry(1, .mixMatched, bpm: 120, key: "8B"), entry(2, .soundSimilar),
                    entry(3, .modelUnavailableShuffle)].compactMap { $0.provenance?.subtitle }
        XCTAssertEqual(Set(subs).count, 3)
    }

    func testMixMatchedRequiresBPMAndKey() {
        XCTAssertNil(KeepPlayingProvenance(reason: .mixMatched, bpm: nil, camelotKey: "9A"))
        XCTAssertNil(KeepPlayingProvenance(reason: .mixMatched, bpm: 120, camelotKey: nil))
        XCTAssertNil(KeepPlayingProvenance(reason: .mixMatched, bpm: .nan, camelotKey: "9A"))
        let e = entry(1, .mixMatched)
        XCTAssertEqual(e.origin, .keepPlaying(.soundSimilar))
    }

    func testProvenanceSurvivesReorderAndRemovalByOccurrence() {
        let a = entry(1, .mixMatched, bpm: 120, key: "8B")
        let b = entry(1, .noMatchShuffle)
        var state = QueueEditor.State<PlaybackQueueEntry>(queue: [entry(9, .soundSimilar), a, b], currentIndex: 0)
        state = QueueEditor.State(queue: [state.queue[2], state.queue[1], state.queue[0]], currentIndex: 2)
        XCTAssertEqual(state.queue.first { $0.id == a.id }?.provenance, a.provenance)
        state.queue.removeAll { $0.id == a.id }
        XCTAssertEqual(state.queue.first { $0.id == b.id }?.provenance?.reason, .noMatchShuffle)
    }

    func testPersistenceRoundTripAndRestorePlan() async throws {
        let p = try XCTUnwrap(KeepPlayingProvenance(reason: .mixMatched, bpm: 124.4, camelotKey: "9A"))
        var snap = PlaybackStateSnapshot(trackIDs: [1, 2], currentIndex: 0, elapsed: 0, isPlaying: false,
                                         savedAt: Date())
        snap.keepPlayingProvenance = [nil, p]
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(PlaybackStateSnapshot.self, from: data)
        XCTAssertEqual(decoded.keepPlayingProvenance?[1], p)
        let plan = await QueueRestorePlanner.plan(saved: decoded, resolveByID: { Self.row(trackId: $0) },
                                                  resolveBySyncID: { _ in nil })
        XCTAssertEqual(plan?.provenance[1], p)
        XCTAssertNil(plan?.provenance[0])
    }

    func testAccessibilityAndSourceContract() throws {
        let p = try XCTUnwrap(KeepPlayingProvenance(reason: .soundSimilar))
        XCTAssertEqual(QueueAccessibility.rowLabel(position: 2, title: "T", artist: "A", provenance: p),
                       "2, T, A, Recommended by Keep Playing: Sound similar · no BPM/key match available")
        XCTAssertEqual(QueueAccessibility.rowLabel(position: 2, title: "T", artist: "A"), "2, T, A")
        XCTAssertEqual(KeepPlayingProvenance.whyActionName, "Why this track?")
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/KeepPlayingProvenanceTests.swift", with: "Sources/Features/NowPlaying/UpNextView.swift"),
            encoding: .utf8)
        // Same QueueRow serves iOS and macOS rows and gates the action on provenance.
        XCTAssertTrue(src.contains("provenance: player.queueEntries[safe: offset]?.provenance"))
        XCTAssertEqual(src.components(separatedBy: "provenance: player.queueEntries[safe: offset]").count - 1, 2)
        XCTAssertFalse(src.contains("keepPlayingFallbackDetail"))
        XCTAssertTrue(src.contains("if let provenance"))
    }
}
