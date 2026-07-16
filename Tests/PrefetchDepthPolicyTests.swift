import XCTest
@testable import TonearmCore

final class PrefetchDepthPolicyTests: XCTestCase {
    func testRangeIsFreeUpToFive() {
        XCTAssertEqual(PrefetchDepthPolicy.minimum, 0)
        XCTAssertEqual(PrefetchDepthPolicy.maximum, 5)
    }

    func testClamp() {
        XCTAssertEqual(PrefetchDepthPolicy.clamp(-10), 0)
        XCTAssertEqual(PrefetchDepthPolicy.clamp(0), 0)
        XCTAssertEqual(PrefetchDepthPolicy.clamp(2), 2)
        XCTAssertEqual(PrefetchDepthPolicy.clamp(5), 5)
        XCTAssertEqual(PrefetchDepthPolicy.clamp(9), 5)
    }
}
