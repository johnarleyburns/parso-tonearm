import XCTest
@testable import TonearmCore

final class DJTempoNudgePolicyTests: XCTestCase {
    func testNudgeMovesByTheSmallStepAndClampsToTempoRange() {
        XCTAssertEqual(DJTempoNudgePolicy.nudgedValue(current: 1.0, direction: 1, range: 2), 1.1, accuracy: 0.0001)
        XCTAssertEqual(DJTempoNudgePolicy.nudgedValue(current: 1.98, direction: 1, range: 2), 2.0, accuracy: 0.0001)
        XCTAssertEqual(DJTempoNudgePolicy.nudgedValue(current: -1.98, direction: -1, range: 2), -2.0, accuracy: 0.0001)
    }

    func testRepeatTimingLeavesRoomForAnImmediateTap() {
        XCTAssertGreaterThan(DJTempoNudgePolicy.repeatDelayMilliseconds,
                             DJTempoNudgePolicy.repeatIntervalMilliseconds)
        XCTAssertEqual(DJTempoNudgePolicy.stepPercent, 0.1, accuracy: 0.0001)
    }
}
