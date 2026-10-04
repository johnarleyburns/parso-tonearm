import XCTest
import AVFoundation
@testable import TonearmCore

@MainActor
final class TransitionExecutionTests: XCTestCase {
    func testMixPlaybackRateUsesReferenceTempoWithoutChangingKey() {
        XCTAssertEqual(AudioPlayer.mixPlaybackRate(referenceBPM: 128, sourceBPM: 115),
                       Float(128.0 / 115.0), accuracy: 0.0001)
        XCTAssertEqual(AudioPlayer.mixPlaybackRate(referenceBPM: .nan, sourceBPM: 115), 1)
    }

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

    // MARK: - Field test 2026-10-03: beats offset in blends, abrupt blends

    func testStartIsScheduledExactlyAtTheExitWhenThereIsTime() {
        let start = TransitionTiming.start(exit: 180, entry: 4, outgoingNow: 178.5,
                                           outgoingRate: 1, incomingRate: 1.03)
        XCTAssertEqual(start.delaySeconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual(start.incomingItemTime, 4, accuracy: 0.0001)
        XCTAssertFalse(start.isLate)
    }

    func testLateStartJoinsInPhaseInsteadOfAtTheEntryPoint() {
        // The old executor started a late incoming track at its entry point: 0.4 s late here,
        // which is most of a beat at 128 BPM.
        let start = TransitionTiming.start(exit: 180, entry: 4, outgoingNow: 180.3,
                                           outgoingRate: 1, incomingRate: 1.05)
        XCTAssertTrue(start.isLate)
        XCTAssertEqual(start.delaySeconds, TransitionTiming.minimumStartLeadSeconds, accuracy: 0.0001)
        XCTAssertEqual(start.incomingItemTime, 4 + 0.4 * 1.05, accuracy: 0.0001)
    }

    func testMixExpectationUsesBothTracksRates() {
        // Mix at 128: outgoing 120 BPM source plays at 128/120, incoming 125 at 128/125. Over
        // 10 outgoing item-seconds the incoming item advances 10 × (120/125) = 9.6 s, not 10 s
        // (the old mix check assumed 10 s and seeked the tracks 0.4 s apart).
        let expected = TransitionTiming.expectedIncomingTime(
            exit: 100, entry: 2, outgoingNow: 110,
            outgoingRate: 128.0 / 120.0, incomingRate: 128.0 / 125.0)
        XCTAssertEqual(expected, 2 + 9.6, accuracy: 0.0001)
    }

    func testSmallDriftIsNudgedNotSeeked() {
        XCTAssertEqual(TransitionTiming.correction(driftSeconds: 0.003, expectedIncomingTime: 10), .none)
        XCTAssertEqual(TransitionTiming.correction(driftSeconds: 0.02, expectedIncomingTime: 10), .nudgeRate(0.98))
        XCTAssertEqual(TransitionTiming.correction(driftSeconds: -0.05, expectedIncomingTime: 10), .nudgeRate(1.03))
        XCTAssertEqual(TransitionTiming.correction(driftSeconds: 0.2, expectedIncomingTime: 10), .seek(toIncomingTime: 10))
        XCTAssertEqual(TransitionTiming.correction(driftSeconds: .nan, expectedIncomingTime: 10), .none)
    }

    func testLateStartFadesInFromSilence() {
        XCTAssertEqual(TransitionTiming.lateStartGain(outgoingNow: 50, startedAtOutgoing: nil), 1)
        XCTAssertEqual(TransitionTiming.lateStartGain(outgoingNow: 50, startedAtOutgoing: 50), 0)
        XCTAssertEqual(TransitionTiming.lateStartGain(outgoingNow: 51, startedAtOutgoing: 50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TransitionTiming.lateStartGain(outgoingNow: 60, startedAtOutgoing: 50), 1)
    }
}
