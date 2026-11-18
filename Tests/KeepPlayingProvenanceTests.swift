import Testing
@testable import TonearmCore

@MainActor
@Suite struct KeepPlayingProvenanceTests {
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

    @Test func testMixMatchedSubtitle() throws {
        let e = entry(1, .mixMatched, bpm: 124.4, key: "9A")
        #expect(e.provenance?.subtitle == "Mix match · 124.4 BPM · 9A")
        #expect(KeepPlayingProvenance(reason: .mixMatched, bpm: 124, camelotKey: "9A")?.subtitle ==
                       "Mix match · 124 BPM · 9A")
    }

    @Test func testOtherReasonSubtitles() {
        #expect(entry(1, .soundSimilar).provenance?.subtitle == "Sound similar · no BPM/key match available")
        #expect(entry(1, .modelUnavailableShuffle).provenance?.subtitle == "Shuffled · sound model is not ready")
        #expect(entry(1, .noMatchShuffle).provenance?.subtitle ==
                       "Shuffled · no compatible recommendation was available")
    }

    @Test func testMixedTailHasDistinctSubtitles() {
        let subs = [entry(1, .mixMatched, bpm: 120, key: "8B"), entry(2, .soundSimilar),
                    entry(3, .modelUnavailableShuffle)].compactMap { $0.provenance?.subtitle }
        #expect(Set(subs).count == 3)
    }

    @Test func testMixMatchedRequiresBPMAndKey() {
        #expect(KeepPlayingProvenance(reason: .mixMatched, bpm: nil, camelotKey: "9A") == nil)
        #expect(KeepPlayingProvenance(reason: .mixMatched, bpm: 120, camelotKey: nil) == nil)
        #expect(KeepPlayingProvenance(reason: .mixMatched, bpm: .nan, camelotKey: "9A") == nil)
        let e = entry(1, .mixMatched)
        #expect(e.origin == .keepPlaying(.soundSimilar))
    }

    @Test func testProvenanceSurvivesReorderAndRemovalByOccurrence() {
        let a = entry(1, .mixMatched, bpm: 120, key: "8B")
        let b = entry(1, .noMatchShuffle)
        var state = QueueEditor.State<PlaybackQueueEntry>(queue: [entry(9, .soundSimilar), a, b], currentIndex: 0)
        state = QueueEditor.State(queue: [state.queue[2], state.queue[1], state.queue[0]], currentIndex: 2)
        #expect(state.queue.first { $0.id == a.id }?.provenance == a.provenance)
        state.queue.removeAll { $0.id == a.id }
        #expect(state.queue.first { $0.id == b.id }?.provenance?.reason == .noMatchShuffle)
    }

    @Test func testPersistenceRoundTripAndRestorePlan() async throws {
        let p = try #require(KeepPlayingProvenance(reason: .mixMatched, bpm: 124.4, camelotKey: "9A"))
        var snap = PlaybackStateSnapshot(trackIDs: [1, 2], currentIndex: 0, elapsed: 0, isPlaying: false,
                                         savedAt: Date())
        snap.keepPlayingProvenance = [nil, p]
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(PlaybackStateSnapshot.self, from: data)
        #expect(decoded.keepPlayingProvenance?[1] == p)
        let plan = await QueueRestorePlanner.plan(saved: decoded, resolveByID: { Self.row(trackId: $0) },
                                                  resolveBySyncID: { _ in nil })
        #expect(plan?.provenance[1] == p)
        #expect(plan?.provenance[0] == nil)
    }

    @Test func testAccessibilityAndSourceContract() throws {
        let p = try #require(KeepPlayingProvenance(reason: .soundSimilar))
        #expect(QueueAccessibility.rowLabel(position: 2, title: "T", artist: "A", provenance: p) ==
                       "2, T, A, Recommended by Keep Playing: Sound similar · no BPM/key match available")
        #expect(QueueAccessibility.rowLabel(position: 2, title: "T", artist: "A") == "2, T, A")
        #expect(KeepPlayingProvenance.whyActionName == "Why this track?")
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/KeepPlayingProvenanceTests.swift", with: "Sources/Features/NowPlaying/UpNextView.swift"),
            encoding: .utf8)
        // Same QueueRow serves iOS and macOS rows and gates the action on provenance.
        #expect(src.contains("provenance: player.queueEntries[safe: offset]?.provenance"))
        #expect(src.components(separatedBy: "provenance: player.queueEntries[safe: offset]").count - 1 == 2)
        #expect(!src.contains("keepPlayingFallbackDetail"))
        #expect(src.contains("if let provenance"))
    }
}
