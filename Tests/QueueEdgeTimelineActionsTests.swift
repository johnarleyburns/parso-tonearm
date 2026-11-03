#if !os(watchOS)
import XCTest
@testable import TonearmCore

/// Drives the real `AudioPlayer` queue and ledger, then reads the per-edge rows the Queue renders
/// and invokes the detail-sheet actions. Removing the occurrence/snapshot wiring in
/// `QueueEdgeResolver` or the `noBlendEdges` handling in the player makes these fail.
@MainActor
final class QueueEdgeTimelineActionsTests: XCTestCase {
    private let source = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil,
                                title: "S", addedAt: Date(), lastResolvedAt: nil,
                                followUpdates: false, licenseText: nil, memberCapHit: false)

    private func row(_ id: Int64) -> TrackRow {
        let track = Track(id: id, albumId: 1, sourceId: 1, title: "Track \(id)", trackNo: nil, discNo: nil,
                          durationSec: 185, codec: "MP3", sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "\(id)")
        let asset = Asset(id: id, trackId: id, kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://example.invalid/\(id).mp3", altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
        return TrackRow(track: track, album: Album(id: 1, sourceId: 1, title: "A", artist: nil),
                        source: source, asset: asset)
    }

    private var player: AudioPlayer { AudioPlayer.shared }

    override func setUp() async throws {
        player.repeatMode = .off
        player.smartTransitionsEnabled = true
        player.queue = [row(1), row(1), row(2)] // A→A duplicate, then A→B
        player.replaceQueueOccurrences()
        player.index = 0
    }

    override func tearDown() async throws {
        player.transitionExecution.cancelAll(reason: .stopped)
        player.noBlendEdges = []
        player.queue = []
    }

    private func edges() -> [QueueEdgeRow] {
        QueueEdgeResolver.rows(
            trackIDs: player.queue.map(\.track.id), currentIndex: player.index, repeatMode: player.repeatMode,
            smartTransitionsEnabled: player.smartTransitionsEnabled, live: player.transitionPresentation,
            occurrences: player.queueOccurrences,
            snapshot: { self.player.transitionExecutionSnapshot(afterQueueIndex: $0) }, noBlend: player.noBlendEdges)
    }

    private func key(_ from: Int, _ to: Int) -> TransitionEdgeKey {
        TransitionEdgeKey(from: player.queueOccurrences[from], to: player.queueOccurrences[to])
    }

    private func schedule(_ k: TransitionEdgeKey) {
        player.mixDecksExecution(.scheduled(key: k, generation: player.mixDecksQueueGeneration,
                                            requested: .phraseBlend, planned: .phraseBlend, executed: .plainCrossfade,
                                            reason: nil, overlapStartFrame: 100, overlapEndFrame: 700,
                                            handoffFrame: 700, sampleRate: 48_000))
    }

    func testDuplicateEdgesAreDistinctAndSnapshotsAttachOnlyToTheirPair() {
        schedule(key(1, 2))
        let rows = edges()
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].key, rows[1].key)
        XCTAssertNil(rows[0].snapshot)
        XCTAssertEqual(rows[1].snapshot?.key, key(1, 2))
        XCTAssertEqual(rows[1].presentation.actualStyle, .plainCrossfade)
    }

    func testDeniedEdgeShowsFallbackAndOffersRetryOnlyThere() {
        player.transitionExecution.record(key(0, 1), generation: player.mixDecksQueueGeneration,
                                          .denied(.admissionDenied("memory"), readiness: .failed("memory")))
        let rows = edges()
        XCTAssertEqual(rows[0].presentation.phase, .fallback)
        XCTAssertTrue(rows[0].canRetry)
        XCTAssertFalse(rows[1].canRetry)
        XCTAssertTrue(player.retryTransition(key(0, 1)))
        XCTAssertFalse(player.retryTransition(key(1, 2)), "no terminal snapshot: nothing to retry")
    }

    func testPlayWithoutBlendMutatesOnlyThatOccurrencePair() {
        schedule(key(0, 1))
        schedule(key(1, 2))
        XCTAssertTrue(player.playWithoutBlend(key(1, 2)))
        XCTAssertEqual(player.noBlendEdges, [key(1, 2)])
        let rows = edges()
        XCTAssertFalse(rows[0].playsWithoutBlend)
        XCTAssertTrue(rows[1].playsWithoutBlend)
        XCTAssertEqual(rows[1].summary, "Playing without a blend")
        XCTAssertNil(player.mixDecksUpcomingIndex(after: 1), "scheduler must not blend into the edge")
    }

    func testPlayWithoutBlendRefusesAudibleOrNonAdjacentEdge() {
        schedule(key(0, 1))
        player.mixDecksExecution(.overlapBegan(key: key(0, 1), generation: player.mixDecksQueueGeneration, atFrame: 100))
        XCTAssertFalse(player.playWithoutBlend(key(0, 1)))
        XCTAssertFalse(player.playWithoutBlend(key(0, 2)))
        XCTAssertTrue(player.noBlendEdges.isEmpty)
    }

    func testSelectionFollowsReorderAndDropsOnDeleteOrReplacement() {
        let selected = edges()[1].key
        player.moveQueueItems(fromOffsets: IndexSet(integer: 0), toOffset: 3) // A, A, B → A, B, A
        let moved = QueueEdgeResolver.resolve(selected, in: edges())
        XCTAssertNil(moved, "neighbour changed: the pair is gone, selection invalidates")
        let kept = edges()[0].key
        player.removeFromQueue(at: 2)
        XCTAssertNotNil(QueueEdgeResolver.resolve(kept, in: edges()), "untouched pair survives an unrelated delete")
        player.queue = [row(1), row(2)]
        player.replaceQueueOccurrences()
        XCTAssertNil(QueueEdgeResolver.resolve(kept, in: edges()), "replacement invalidates by occurrence")
    }

    func testNoBlendRequestsArePrunedWhenAPairIsBroken() {
        schedule(key(1, 2))
        XCTAssertTrue(player.playWithoutBlend(key(1, 2)))
        player.removeFromQueue(at: 2)
        XCTAssertTrue(player.noBlendEdges.isEmpty)
    }

    func testLoopWrapEdgeHasItsOwnOccurrenceKey() {
        player.repeatMode = .all
        let rows = edges()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[2].key.executionKey, key(2, 0))
    }

    func testAccessibilityLabelsCarryRoleAndSpokenDuration() {
        XCTAssertEqual(QueueAccessibility.rowValue(isCurrent: false, isUpNext: true, duration: 185),
                       "Up next, 3 minutes, 5 seconds")
        XCTAssertEqual(QueueAccessibility.rowValue(isCurrent: true, duration: 60), "Now playing, 1 minute")
        XCTAssertEqual(QueueAccessibility.edgeValue(isActive: true, isSelected: true, incomingPosition: 2),
                       "Blending now, Into track 2, Selected")
    }
}
#endif
