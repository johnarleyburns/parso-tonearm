import XCTest

@testable import TonearmDiscovery

final class DiscoverySamplingPolicyTests: XCTestCase {
    func testShortTrackGetsOneZeroPaddedWindow() {
        XCTAssertEqual(DiscoverySamplingPolicy.windowStarts(durationSeconds: 5), [0])
        XCTAssertEqual(DiscoverySamplingPolicy.windowStarts(durationSeconds: 10), [0])
    }

    func testWindowCountIsMinTwelveAndCeilDurationOverTen() {
        // 11s -> ceil(11/10) = 2 windows over [0, 1]
        XCTAssertEqual(DiscoverySamplingPolicy.windowStarts(durationSeconds: 11).count, 2)
        // 125s -> ceil(125/10) = 13, capped at 12
        XCTAssertEqual(DiscoverySamplingPolicy.windowStarts(durationSeconds: 125).count, 12)
    }

    func testWindowsAreAscendingAndBoundedByDurationMinusTen() {
        let duration = 200.0
        let starts = DiscoverySamplingPolicy.windowStarts(durationSeconds: duration)
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertEqual(starts.first, 0)
        XCTAssertEqual(starts.last!, duration - 10, accuracy: 0.001)
    }

    func testNonFiniteOrNonPositiveDurationFallsBackToOneWindow() {
        XCTAssertEqual(DiscoverySamplingPolicy.windowStarts(durationSeconds: .nan), [0])
        XCTAssertEqual(DiscoverySamplingPolicy.windowStarts(durationSeconds: 0), [0])
        XCTAssertEqual(DiscoverySamplingPolicy.windowStarts(durationSeconds: -5), [0])
    }
}
