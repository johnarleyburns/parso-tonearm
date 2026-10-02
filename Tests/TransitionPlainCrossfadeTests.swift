import XCTest
@testable import TonearmCore

/// Real report: a mix edge labelled "Plain crossfade" played as a hard cut — the plan's fade
/// length was 0, so the player never started the incoming track early.
final class TransitionPlainCrossfadeTests: XCTestCase {
    func testPlainCrossfadesAlwaysHaveARealFade() {
        let unprepared = TransitionPlanner.plan(from: nil, to: nil, context: .init(
            fromTrackID: 1, toTrackID: 2, fromDuration: 200, toDuration: 200, prepState: .notPrepared))
        XCTAssertEqual(unprepared.style, .plainCrossfade)
        XCTAssertGreaterThanOrEqual(unprepared.overlapSeconds, 6)

        let chosen = TransitionPlanner.plan(from: nil, to: nil, context: .init(
            fromTrackID: 1, toTrackID: 2, fromDuration: 200, toDuration: 200, userChosePlainFade: true))
        XCTAssertEqual(chosen.style, .plainCrossfade)
        XCTAssertEqual(chosen.overlapSeconds, TransitionPlanner.plainCrossfadeSeconds)
    }
}
