import XCTest
@testable import TonearmCore

final class WatchTransferPlannerTests: XCTestCase {

    func testEmptyDesiredProducesNoOps() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: [],
            manifestOnWatch: [],
            currentItems: [])
        XCTAssertTrue(plan.toEnqueue.isEmpty)
        XCTAssertTrue(plan.toRetry.isEmpty)
        XCTAssertTrue(plan.toCancel.isEmpty)
    }

    func testNewKeyEnqueues() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: ["t1"],
            manifestOnWatch: [],
            currentItems: [])
        XCTAssertEqual(plan.toEnqueue.count, 1)
        XCTAssertEqual(plan.toEnqueue[0].key, "t1")
        XCTAssertEqual(plan.toEnqueue[0].origin, .single)
    }

    func testAlreadyOnWatchSkips() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: ["t1"],
            manifestOnWatch: ["t1"],
            currentItems: [])
        XCTAssertTrue(plan.toEnqueue.isEmpty, "track already on watch should not be re-enqueued")
    }

    func testAlreadyQueuedSkips() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: ["t1"],
            manifestOnWatch: [],
            currentItems: [WatchTransferItem(trackKey: "t1", state: .queued)])
        XCTAssertTrue(plan.toEnqueue.isEmpty, "already queued should skip")
    }

    func testAlreadySendingSkips() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: ["t1"],
            manifestOnWatch: [],
            currentItems: [WatchTransferItem(trackKey: "t1", state: .sending)])
        XCTAssertTrue(plan.toEnqueue.isEmpty)
    }

    func testFailedItemsRetry() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: ["t1"],
            manifestOnWatch: [],
            currentItems: [WatchTransferItem(trackKey: "t1", state: .failed, errorText: "timeout")])
        XCTAssertEqual(plan.toRetry, ["t1"])
        XCTAssertTrue(plan.toEnqueue.isEmpty, "failed should retry, not enqueue")
    }

    func testAlreadySentButNotInManifestDoesNotReEnqueue() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: ["t1"],
            manifestOnWatch: [],
            currentItems: [WatchTransferItem(trackKey: "t1", state: .sent)])
        XCTAssertTrue(plan.toEnqueue.isEmpty)
    }

    func testNonTransferableSkipped() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: ["t1", "t2"],
            manifestOnWatch: [],
            currentItems: [],
            isTransferable: { $0 == "t2" })
        XCTAssertEqual(plan.toEnqueue.count, 1)
        XCTAssertEqual(plan.toEnqueue[0].key, "t2")
    }

    func testCancelsStaleActiveItems() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: [],
            manifestOnWatch: [],
            currentItems: [WatchTransferItem(trackKey: "t1", state: .queued)])
        XCTAssertEqual(plan.toCancel, ["t1"], "active item no longer desired should be cancelled")
    }

    func testDoesNotCancelSentItems() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: [],
            manifestOnWatch: ["t1"],
            currentItems: [WatchTransferItem(trackKey: "t1", state: .sent)])
        XCTAssertTrue(plan.toCancel.isEmpty, "sent items should not be cancelled")
    }

    func testDeduplicatesRetriesOverEnqueues() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: ["t1"],
            manifestOnWatch: [],
            currentItems: [WatchTransferItem(trackKey: "t1", state: .failed, errorText: "err")])
        XCTAssertEqual(plan.toRetry, ["t1"])
        XCTAssertTrue(plan.toEnqueue.isEmpty)
    }

    func testFailedWithoutErrorSkips() {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: ["t1"],
            manifestOnWatch: [],
            currentItems: [WatchTransferItem(trackKey: "t1", state: .failed, errorText: nil)])
        XCTAssertTrue(plan.toEnqueue.isEmpty, "failed without error text was not retired, should be skipped")
        XCTAssertTrue(plan.toRetry.isEmpty)
    }
}
