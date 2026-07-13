import XCTest
@testable import Tonearm

final class CacheLimitPolicyTests: XCTestCase {
    private let mb: Int64 = 1024 * 1024

    func testBelowFloorClampsUpWhenDiskAllows() {
        let result = CacheLimitPolicy.validate(requestedBytes: 50 * mb, freeDiskBytes: 10_000 * mb)
        XCTAssertEqual(result.allowedBytes, CacheLimitPolicy.minimumBytes)
        XCTAssertNotNil(result.reason)
    }

    func testAboveCeilingClampsToEightyPercentOfFreeDisk() {
        let result = CacheLimitPolicy.validate(requestedBytes: 10_000 * mb, freeDiskBytes: 1_000 * mb)
        XCTAssertEqual(result.allowedBytes, 800 * mb)
        XCTAssertEqual(result.reason, "Cache is limited to 80% of free disk space.")
    }

    func testExactlyAtBoundsPasses() {
        XCTAssertNil(CacheLimitPolicy.validate(
            requestedBytes: CacheLimitPolicy.minimumBytes,
            freeDiskBytes: 1_000 * mb
        ).reason)
        XCTAssertNil(CacheLimitPolicy.validate(
            requestedBytes: 800 * mb,
            freeDiskBytes: 1_000 * mb
        ).reason)
    }

    func testZeroFreeDiskReturnsZero() {
        let result = CacheLimitPolicy.validate(requestedBytes: 500 * mb, freeDiskBytes: 0)
        XCTAssertEqual(result.allowedBytes, 0)
        XCTAssertEqual(result.reason, "No free disk space is available for cache.")
    }

    func testAbsurdInputsClampSafely() {
        XCTAssertEqual(CacheLimitPolicy.validate(requestedBytes: -1, freeDiskBytes: 1_000 * mb).allowedBytes,
                       CacheLimitPolicy.minimumBytes)
        XCTAssertEqual(CacheLimitPolicy.validate(requestedBytes: Int64.max, freeDiskBytes: 10 * mb).allowedBytes,
                       8 * mb)
    }
}
