import XCTest
@testable import TonearmCore

/// Typed queue provenance: listener-next > listener-queued > context > Keep Playing.
@MainActor
final class QueueOriginPolicyTests: XCTestCase {
    typealias S = QueueEditor.State<PlaybackQueueEntry>

    private func row(_ i: Int) -> TrackRow {
        let t = Track(id: Int64(i), albumId: 1, sourceId: 1, title: "T\(i)", trackNo: i, discNo: nil,
                      durationSec: 120, codec: "MP3", sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "\(i)")
        let a = Album(id: 1, sourceId: 1, title: "Album", artist: "Artist")
        let s = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil, title: "S",
                       addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                       licenseText: nil, memberCapHit: false)
        return TrackRow(track: t, album: a, source: s, asset: nil)
    }

    private func context(_ ids: [Int]) -> S {
        S(queue: ids.map { PlaybackQueueEntry(row: row($0), origin: .context) }, currentIndex: 0)
    }

    private func ids(_ s: S) -> [Int64?] { s.queue.map { $0.row.track.id } }
    private func origins(_ s: S) -> [PlaybackQueueEntry.Origin] { s.queue.map(\.origin) }

    func testListenerNextAndQueuedOrdering() {
        var s = context([1, 2, 3])
        s = S.appendingListenerQueued(row(10), in: s)
        s = S.insertingListenerNext(row(11), in: s)
        XCTAssertEqual(ids(s), [1, 11, 10, 2, 3])
        XCTAssertEqual(origins(s).dropFirst(), [.listenerNext, .listenerQueued, .context, .context])
        s = S.insertingListenerNext(row(12), in: s)
        XCTAssertEqual(ids(s), [1, 12, 11, 10, 2, 3])
    }

    func testQueuedIsFIFOBehindPlayNext() {
        var s = context([1, 2])
        s = S.appendingListenerQueued(row(10), in: s)
        s = S.appendingListenerQueued(row(11), in: s)
        s = S.insertingListenerNext(row(12), in: s)
        XCTAssertEqual(ids(s), [1, 12, 10, 11, 2])
    }

    func testKeepPlayingAppendsAtTailAndListenerStaysAhead() {
        var s = context([1, 2])
        s = S.appendingListenerQueued(row(10), in: s)
        s = S.appendingKeepPlaying([row(20), row(21)], reason: .soundSimilar, in: s)
        XCTAssertEqual(ids(s), [1, 10, 2, 20, 21])
        s = S.insertingListenerNext(row(11), in: s)
        s = S.appendingListenerQueued(row(12), in: s)
        XCTAssertEqual(ids(s), [1, 11, 10, 12, 2, 20, 21])
        XCTAssertEqual(origins(s).last, .keepPlaying(.soundSimilar))
    }

    func testEmptyQueueCreatesSingleListenerEntry() {
        let a = S.insertingListenerNext(row(1), in: S(queue: [], currentIndex: 0))
        XCTAssertEqual(origins(a), [.listenerNext])
        XCTAssertEqual(a.currentIndex, 0)
        let b = S.appendingListenerQueued(row(1), in: S(queue: [], currentIndex: 0))
        XCTAssertEqual(origins(b), [.listenerQueued])
    }

    func testDuplicateTracksKeepDistinctIdentityAndOrigin() {
        var s = context([1, 2])
        s = S.insertingListenerNext(row(2), in: s)
        XCTAssertEqual(ids(s), [1, 2, 2])
        XCTAssertNotEqual(s.queue[1].id, s.queue[2].id)
        let removed = QueueEditor.remove(at: 1, in: s)
        XCTAssertEqual(origins(removed), [.context, .context])
        XCTAssertEqual(removed.queue[1].id, s.queue[2].id)
    }

    func testMoveRetainsOrigin() {
        var s = context([1, 2, 3])
        s = S.insertingListenerNext(row(9), in: s)
        s = QueueEditor.move(from: 1, to: 3, in: s)
        XCTAssertEqual(ids(s), [1, 2, 3, 9])
        XCTAssertEqual(s.queue[3].origin, .listenerNext)
    }

    func testRemoveUnplayedKeepPlayingKeepsEverythingElse() {
        var s = context([1, 2])
        s = S.insertingListenerNext(row(20), in: s)
        s = S.appendingKeepPlaying([row(20), row(21)], reason: .mixMatched, in: s)
        let cleaned = S.removingUnplayedKeepPlaying(in: s)
        XCTAssertEqual(ids(cleaned), [1, 20, 2])
        XCTAssertEqual(origins(cleaned), [.context, .listenerNext, .context])
    }

    func testFreshPlayDropsOldProvenance() {
        let player = AudioPlayer.shared
        player.keepPlayingEnabled = false
        player.resetRestoreForTesting()
        player.shuffle = false
        player.play(tracks: [row(1), row(2)], startAt: 0)
        player.finishKeepPlayingExtension(with: [row(30)], isFallback: false, reason: nil,
                                          recommendation: .mixMatched)
        XCTAssertEqual(player.queueEntries.last?.origin, .keepPlaying(.mixMatched))
        player.play(tracks: [row(3), row(4)], startAt: 0)
        XCTAssertNil(player.keepPlayingExtensionTask)
        XCTAssertEqual(player.queueEntries.map(\.origin), [.context, .context])
        XCTAssertEqual(player.queue.map(\.id), [row(3).id, row(4).id])
        XCTAssertTrue(player.keepPlayingAutoAddedTrackIDs.isEmpty)
        player.removeFromQueue(atOffsets: IndexSet(0..<player.queue.count))
    }
}
