import XCTest
@testable import Tonearm

/// T3.5 — prefetch depth gating: free clamps to 1; Pro honors deeper values.
final class PrefetchDepthTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProEntitlement.clear()
    }

    override func tearDown() {
        ProEntitlement.clear()
        super.tearDown()
    }

    func testFreeClampsToOne() {
        XCTAssertEqual(ProGating.clampedPrefetchDepth(5, isPro: false), 1)
        XCTAssertEqual(ProGating.clampedPrefetchDepth(3, isPro: false), 1)
        XCTAssertEqual(ProGating.clampedPrefetchDepth(1, isPro: false), 1)
    }

    func testFreeAllowsZeroAndOne() {
        XCTAssertEqual(ProGating.clampedPrefetchDepth(0, isPro: false), 0)
        XCTAssertEqual(ProGating.clampedPrefetchDepth(1, isPro: false), 1)
    }

    func testProHonorsDeeperDepth() {
        XCTAssertEqual(ProGating.clampedPrefetchDepth(5, isPro: true), 5)
        XCTAssertEqual(ProGating.clampedPrefetchDepth(3, isPro: true), 3)
    }

    func testLockDetection() {
        XCTAssertTrue(ProGating.isPrefetchDepthLocked(2, isPro: false))
        XCTAssertFalse(ProGating.isPrefetchDepthLocked(1, isPro: false))
        XCTAssertFalse(ProGating.isPrefetchDepthLocked(5, isPro: true))
    }

    // Free-tier keeps depth 1 (never 0) so near-gapless + Opus-when-ready still
    // work — the mechanism is free; only depth beyond 1 is sold (D7).
    func testFreeDepthOnePreservesNearGaplessMechanism() {
        let effective = ProGating.clampedPrefetchDepth(2, isPro: false)
        XCTAssertGreaterThanOrEqual(effective, 1)
    }
}
