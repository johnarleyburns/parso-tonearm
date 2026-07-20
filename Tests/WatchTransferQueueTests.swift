import XCTest
@testable import TonearmCore

final class WatchTransferQueueTests: XCTestCase {

    func testInitialStateIsIdle() {
        let queue = WatchTransferQueue()
        XCTAssertEqual(queue.state, .idle)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testEnqueueAddsItem() {
        var queue = WatchTransferQueue()
        let added = queue.enqueue(key: "t1")
        XCTAssertTrue(added)
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(queue.items[0].state, .queued)
    }

    func testEnqueueDeduplicate() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        let added = queue.enqueue(key: "t1")
        XCTAssertFalse(added, "duplicate enqueue should be rejected")
        XCTAssertEqual(queue.items.count, 1)
    }

    func testStartChangesState() {
        var queue = WatchTransferQueue()
        queue.start()
        XCTAssertEqual(queue.state, .running)
    }

    func testPauseWhileRunning() {
        var queue = WatchTransferQueue()
        queue.start()
        queue.pause()
        XCTAssertEqual(queue.state, .paused)
    }

    func testPauseWhileIdleDoesNothing() {
        var queue = WatchTransferQueue()
        queue.pause()
        XCTAssertEqual(queue.state, .idle)
    }

    func testResumeWhilePaused() {
        var queue = WatchTransferQueue()
        queue.start()
        queue.pause()
        queue.resume()
        XCTAssertEqual(queue.state, .running)
    }

    func testMarkSendingOnlyWhenRunning() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        let ok = queue.markSending(key: "t1")
        XCTAssertFalse(ok, "cannot send when idle")
    }

    func testMarkSendingWorksWhenRunning() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        queue.start()
        let ok = queue.markSending(key: "t1")
        XCTAssertTrue(ok)
        XCTAssertEqual(queue.inFlightCount, 1)
    }

    func testMaxInFlightEnforced() {
        var queue = WatchTransferQueue(maxInFlight: 1)
        _ = queue.enqueue(key: "t1")
        _ = queue.enqueue(key: "t2")
        queue.start()
        XCTAssertTrue(queue.markSending(key: "t1"))
        XCTAssertFalse(queue.markSending(key: "t2"), "maxInFlight should block second send")
    }

    func testMarkSentTransitionsState() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        queue.start()
        _ = queue.markSending(key: "t1")
        let ok = queue.markSent(key: "t1", bytes: 1024)
        XCTAssertTrue(ok)
        XCTAssertEqual(queue.items[0].state, .sent)
        XCTAssertEqual(queue.items[0].bytes, 1024)
        XCTAssertEqual(queue.inFlightCount, 0)
    }

    func testMarkFailedTransitionsState() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        queue.start()
        _ = queue.markSending(key: "t1")
        let ok = queue.markFailed(key: "t1", error: "Network error")
        XCTAssertTrue(ok)
        XCTAssertEqual(queue.items[0].state, .failed)
        XCTAssertEqual(queue.items[0].errorText, "Network error")
    }

    func testRetryResetsToQueued() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        queue.start()
        _ = queue.markSending(key: "t1")
        _ = queue.markFailed(key: "t1", error: "err")
        let ok = queue.retry(key: "t1")
        XCTAssertTrue(ok)
        XCTAssertEqual(queue.items[0].state, .queued)
        XCTAssertNil(queue.items[0].errorText)
    }

    func testCancelRemovesNonSentItem() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        let ok = queue.cancel(key: "t1")
        XCTAssertTrue(ok)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testCancelSendingRemovesItem() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        queue.start()
        _ = queue.markSending(key: "t1")
        let ok = queue.cancel(key: "t1")
        XCTAssertTrue(ok)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testCancelSentReturnsFalse() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        queue.start()
        _ = queue.markSending(key: "t1")
        _ = queue.markSent(key: "t1", bytes: 100)
        let ok = queue.cancel(key: "t1")
        XCTAssertFalse(ok, "sent items should not be cancellable")
        XCTAssertEqual(queue.items.count, 1)
    }

    func testCancelAllActiveClearsQueue() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        _ = queue.enqueue(key: "t2")
        queue.start()
        _ = queue.markSending(key: "t1")
        _ = queue.markSent(key: "t1", bytes: 100)
        queue.cancelAllActive()
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(queue.items[0].state, .sent)
        XCTAssertEqual(queue.state, .idle)
    }

    func testNextCandidatesReturnsQueuedItems() {
        var queue = WatchTransferQueue(maxInFlight: 2)
        _ = queue.enqueue(key: "t1")
        _ = queue.enqueue(key: "t2")
        _ = queue.enqueue(key: "t3")
        queue.start()
        let candidates = queue.nextCandidates()
        XCTAssertEqual(candidates, ["t1", "t2"])
    }

    func testNextCandidatesRespectsMaxInFlight() {
        var queue = WatchTransferQueue(maxInFlight: 1)
        _ = queue.enqueue(key: "t1")
        _ = queue.enqueue(key: "t2")
        queue.start()
        _ = queue.markSending(key: "t1")
        let candidates = queue.nextCandidates()
        XCTAssertTrue(candidates.isEmpty, "no more capacity")
    }

    func testNextCandidatesEmptyWhenPaused() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        queue.start()
        queue.pause()
        let candidates = queue.nextCandidates()
        XCTAssertTrue(candidates.isEmpty, "paused queue should return no candidates")
    }

    func testActiveTrackCounts() {
        var queue = WatchTransferQueue()
        _ = queue.enqueue(key: "t1")
        _ = queue.enqueue(key: "t2")
        queue.start()
        _ = queue.markSending(key: "t1")
        XCTAssertEqual(queue.activeCount, 2)
        XCTAssertEqual(queue.queuedKeys, ["t2"])
        XCTAssertEqual(queue.inFlightKeys, ["t1"])
    }
}
