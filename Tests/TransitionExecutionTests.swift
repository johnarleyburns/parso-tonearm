import XCTest
import AVFoundation
@testable import TonearmCore

@MainActor
final class TransitionExecutionTests: XCTestCase {
    func testHostTimeMathUsesPlaybackRate() {
        var timebase: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                                        sourceClock: CMClockGetHostTimeClock(),
                                                        timebaseOut: &timebase), noErr)
        guard let timebase else { return }
        CMTimebaseSetRate(timebase, rate: 2)
        let mapped = AudioPlayer.transitionHostTime(
            exitSeconds: 12, currentItemTime: CMTime(seconds: 10, preferredTimescale: 600),
            timebase: timebase,
            hostTime: CMTime(seconds: 100, preferredTimescale: 600))
        XCTAssertEqual(mapped.seconds, 101, accuracy: 0.01)
    }

    func testRateRampReturnsToUnityOncePerBeat() {
        let ramp = AudioPlayer.transitionRateRamp(start: 0.98, end: 1, beats: 16, bpm: 120)
        XCTAssertEqual(ramp.count, 17)
        XCTAssertEqual(ramp.first?.rate ?? 0, 0.98, accuracy: 0.0001)
        XCTAssertEqual(ramp.last?.rate ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(ramp.last?.offset ?? 0, 8, accuracy: 0.0001)
    }

    func testRemoteDowngradeDecisionIsExplicit() {
        XCTAssertFalse(AudioPlayer.shouldDowngradeTransition(isRemote: false, likelyBufferedByExit: false))
        XCTAssertFalse(AudioPlayer.shouldDowngradeTransition(isRemote: true, likelyBufferedByExit: true))
        XCTAssertTrue(AudioPlayer.shouldDowngradeTransition(isRemote: true, likelyBufferedByExit: false))
    }

    func testDriftCorrectionIsBoundedToHalfPercentForOneBeat() {
        XCTAssertEqual(AudioPlayer.transitionDriftCorrection(driftSeconds: 0.015), 0)
        XCTAssertEqual(AudioPlayer.transitionDriftCorrection(driftSeconds: 0.016), -0.005)
        XCTAssertEqual(AudioPlayer.transitionDriftCorrection(driftSeconds: -0.016), 0.005)
        XCTAssertEqual(AudioPlayer.transitionDriftCorrection(driftSeconds: .nan), 0)
    }
}
