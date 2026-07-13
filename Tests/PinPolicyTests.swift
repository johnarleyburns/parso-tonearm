import XCTest

@testable import Tonearm

final class PinPolicyTests: XCTestCase {

    func testPinExceedsCacheLimitEvictsOnlyUnpinnedAndReportsOverLimit() {
        let items = [
            item("pinned-a", bytes: 900, seconds: 0, pinned: true),
            item("pinned-b", bytes: 400, seconds: 1, pinned: true),
            item("loose", bytes: 300, seconds: 2, pinned: false),
        ]

        let plan = PinPolicy.evictionPlan(items: items, cacheLimitBytes: 1_000, proEnabled: true)

        XCTAssertEqual(plan.evictKeys, ["loose"])
        XCTAssertEqual(plan.protectedKeys, ["pinned-a", "pinned-b"])
        XCTAssertEqual(plan.bytesAfterEviction, 1_300)
        XCTAssertEqual(plan.overLimitBytes, 300)
        XCTAssertEqual(plan.pinnedBytes, 1_300)
    }

    func testUnpinMakesItemEligibleForLRUEviction() {
        let pinned = [
            item("album", bytes: 700, seconds: 0, pinned: true),
            item("recent", bytes: 500, seconds: 10, pinned: false),
        ]
        let unpinned = PinPolicy.setPinned(false, key: "album", in: pinned)

        let plan = PinPolicy.evictionPlan(items: unpinned, cacheLimitBytes: 600, proEnabled: true)

        XCTAssertEqual(plan.evictKeys, ["album"])
        XCTAssertTrue(plan.protectedKeys.isEmpty)
        XCTAssertEqual(plan.bytesAfterEviction, 500)
    }

    func testPinnedContentIsNeverLRUEvictedWhenProIsActive() {
        let items = [
            item("old-pinned", bytes: 600, seconds: 0, pinned: true),
            item("old-loose", bytes: 300, seconds: 1, pinned: false),
            item("new-loose", bytes: 300, seconds: 2, pinned: false),
        ]

        let plan = PinPolicy.evictionPlan(items: items, cacheLimitBytes: 600, proEnabled: true)

        XCTAssertEqual(plan.evictKeys, ["old-loose", "new-loose"])
        XCTAssertEqual(plan.protectedKeys, ["old-pinned"])
        XCTAssertEqual(plan.bytesAfterEviction, 600)
        XCTAssertEqual(plan.overLimitBytes, 0)
    }

    func testPinDuringProDowngradeKeepsStateButRemovesProtection() {
        let items = [
            item("old-pinned", bytes: 600, seconds: 0, pinned: true),
            item("new-loose", bytes: 500, seconds: 10, pinned: false),
        ]

        let plan = PinPolicy.evictionPlan(items: items, cacheLimitBytes: 700, proEnabled: false)

        XCTAssertEqual(plan.availability, .inactiveRequiresPro)
        XCTAssertTrue(plan.protectedKeys.isEmpty)
        XCTAssertEqual(plan.evictKeys, ["old-pinned"])
        XCTAssertEqual(items.first?.isPinned, true)
    }

    func testProtectedCurrentWriteIsNotEvictedEvenWhenUnpinned() {
        let items = [
            item("current", bytes: 900, seconds: 0, pinned: false),
            item("older", bytes: 300, seconds: -10, pinned: false),
        ]

        let plan = PinPolicy.evictionPlan(
            items: items,
            cacheLimitBytes: 500,
            proEnabled: true,
            protectedKey: "current"
        )

        XCTAssertEqual(plan.protectedKeys, ["current"])
        XCTAssertEqual(plan.evictKeys, ["older"])
        XCTAssertEqual(plan.overLimitBytes, 400)
    }

    func testUnlimitedCacheDoesNotEvict() {
        let items = [
            item("a", bytes: 1_000, seconds: 0, pinned: false),
            item("b", bytes: 2_000, seconds: 1, pinned: true),
        ]

        let plan = PinPolicy.evictionPlan(items: items, cacheLimitBytes: 0, proEnabled: true)

        XCTAssertEqual(plan.evictKeys, [])
        XCTAssertEqual(plan.bytesAfterEviction, 3_000)
        XCTAssertEqual(plan.overLimitBytes, 0)
        XCTAssertEqual(plan.protectedKeys, ["b"])
    }

    private func item(_ key: String, bytes: Int64, seconds: TimeInterval, pinned: Bool) -> PinPolicy.Item {
        PinPolicy.Item(
            key: key,
            bytes: bytes,
            lastAccessedAt: Date(timeIntervalSince1970: seconds),
            isPinned: pinned
        )
    }
}
