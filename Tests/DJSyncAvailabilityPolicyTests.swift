import XCTest
@testable import TonearmCore

final class DJSyncAvailabilityPolicyTests: XCTestCase {
    func testSyncRequiresARealPositiveBPM() {
        XCTAssertFalse(DJSyncAvailabilityPolicy.canSync(bpm: nil))
        XCTAssertFalse(DJSyncAvailabilityPolicy.canSync(bpm: 0))
        XCTAssertFalse(DJSyncAvailabilityPolicy.canSync(bpm: .nan))
        XCTAssertTrue(DJSyncAvailabilityPolicy.canSync(bpm: 124.5))
    }
}
