import Testing

@testable import TonearmDiscovery

@Suite struct DiscoverySamplingPolicyTests {
    @Test func testShortTrackGetsOneZeroPaddedWindow() {
        #expect(DiscoverySamplingPolicy.windowStarts(durationSeconds: 5) == [0])
        #expect(DiscoverySamplingPolicy.windowStarts(durationSeconds: 10) == [0])
    }

    @Test func testWindowCountIsMinTwelveAndCeilDurationOverTen() {
        // 11s -> ceil(11/10) = 2 windows over [0, 1]
        #expect(DiscoverySamplingPolicy.windowStarts(durationSeconds: 11).count == 2)
        // 125s -> ceil(125/10) = 13, capped at 12
        #expect(DiscoverySamplingPolicy.windowStarts(durationSeconds: 125).count == 12)
    }

    @Test func testWindowsAreAscendingAndBoundedByDurationMinusTen() {
        let duration = 200.0
        let starts = DiscoverySamplingPolicy.windowStarts(durationSeconds: duration)
        #expect(starts == starts.sorted())
        #expect(starts.first == 0)
        #expect(abs(starts.last! - (duration - 10)) <= 0.001)
    }

    @Test func testNonFiniteOrNonPositiveDurationFallsBackToOneWindow() {
        #expect(DiscoverySamplingPolicy.windowStarts(durationSeconds: .nan) == [0])
        #expect(DiscoverySamplingPolicy.windowStarts(durationSeconds: 0) == [0])
        #expect(DiscoverySamplingPolicy.windowStarts(durationSeconds: -5) == [0])
    }
}
