import Testing
@testable import TonearmWatchCore

@Suite struct WatchScrubPolicyTests {
    @Test func testInteractivity() {
        #expect(WatchScrubPolicy.isInteractive(duration: 100, isLocal: true, isBusy: false, isLuminanceReduced: false))
        #expect(!WatchScrubPolicy.isInteractive(duration: 0, isLocal: true, isBusy: false, isLuminanceReduced: false))
        #expect(!WatchScrubPolicy.isInteractive(duration: .nan, isLocal: true, isBusy: false, isLuminanceReduced: false))
        #expect(!WatchScrubPolicy.isInteractive(duration: 100, isLocal: false, isBusy: false, isLuminanceReduced: false))
        #expect(!WatchScrubPolicy.isInteractive(duration: 100, isLocal: true, isBusy: true, isLuminanceReduced: false))
        #expect(!WatchScrubPolicy.isInteractive(duration: 100, isLocal: true, isBusy: false, isLuminanceReduced: true))
    }

    @Test func testLocationMapsAndClampsAtEdges() {
        #expect(abs(WatchScrubPolicy.time(forLocation: 50, width: 100, duration: 200) - 100) <= 0.001)
        #expect(WatchScrubPolicy.time(forLocation: -20, width: 100, duration: 200) == 0)
        #expect(abs(WatchScrubPolicy.time(forLocation: 500, width: 100, duration: 200) - 199.5) <= 0.001)
        #expect(WatchScrubPolicy.time(forLocation: 10, width: 0, duration: 200) == 0)
        #expect(WatchScrubPolicy.time(forLocation: 10, width: 100, duration: 0) == 0)
    }

    @Test func testAdjustableSteps() {
        #expect(abs(WatchScrubPolicy.adjustedTime(from: 10, duration: 200, direction: 1) - 20) <= 0.001)
        #expect(WatchScrubPolicy.adjustedTime(from: 2, duration: 200, direction: -1) == 0)
        #expect(abs(WatchScrubPolicy.adjustedTime(from: 199, duration: 200, direction: 1) - 199.5) <= 0.001)
    }

    @Test func testScrubAndCommittedWinOverStalePlayerTime() {
        #expect(WatchScrubPolicy.displayed(scrub: 40, committed: 30, playerElapsed: 5) == 40)
        #expect(WatchScrubPolicy.displayed(scrub: nil, committed: 30, playerElapsed: 5) == 30)
        #expect(WatchScrubPolicy.displayed(scrub: nil, committed: nil, playerElapsed: 5) == 5)
    }
}
