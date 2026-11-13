import XCTest
@testable import TonearmWatchCore

final class WatchScrubPolicyTests: XCTestCase {
    func testInteractivity() {
        XCTAssertTrue(WatchScrubPolicy.isInteractive(duration: 100, isLocal: true, isBusy: false, isLuminanceReduced: false))
        XCTAssertFalse(WatchScrubPolicy.isInteractive(duration: 0, isLocal: true, isBusy: false, isLuminanceReduced: false))
        XCTAssertFalse(WatchScrubPolicy.isInteractive(duration: .nan, isLocal: true, isBusy: false, isLuminanceReduced: false))
        XCTAssertFalse(WatchScrubPolicy.isInteractive(duration: 100, isLocal: false, isBusy: false, isLuminanceReduced: false))
        XCTAssertFalse(WatchScrubPolicy.isInteractive(duration: 100, isLocal: true, isBusy: true, isLuminanceReduced: false))
        XCTAssertFalse(WatchScrubPolicy.isInteractive(duration: 100, isLocal: true, isBusy: false, isLuminanceReduced: true))
    }

    func testLocationMapsAndClampsAtEdges() {
        XCTAssertEqual(WatchScrubPolicy.time(forLocation: 50, width: 100, duration: 200), 100, accuracy: 0.001)
        XCTAssertEqual(WatchScrubPolicy.time(forLocation: -20, width: 100, duration: 200), 0)
        XCTAssertEqual(WatchScrubPolicy.time(forLocation: 500, width: 100, duration: 200), 199.5, accuracy: 0.001)
        XCTAssertEqual(WatchScrubPolicy.time(forLocation: 10, width: 0, duration: 200), 0)
        XCTAssertEqual(WatchScrubPolicy.time(forLocation: 10, width: 100, duration: 0), 0)
    }

    func testAdjustableSteps() {
        XCTAssertEqual(WatchScrubPolicy.adjustedTime(from: 10, duration: 200, direction: 1), 20, accuracy: 0.001)
        XCTAssertEqual(WatchScrubPolicy.adjustedTime(from: 2, duration: 200, direction: -1), 0)
        XCTAssertEqual(WatchScrubPolicy.adjustedTime(from: 199, duration: 200, direction: 1), 199.5, accuracy: 0.001)
    }

    func testScrubAndCommittedWinOverStalePlayerTime() {
        XCTAssertEqual(WatchScrubPolicy.displayed(scrub: 40, committed: 30, playerElapsed: 5), 40)
        XCTAssertEqual(WatchScrubPolicy.displayed(scrub: nil, committed: 30, playerElapsed: 5), 30)
        XCTAssertEqual(WatchScrubPolicy.displayed(scrub: nil, committed: nil, playerElapsed: 5), 5)
    }
}
