import XCTest
@testable import TonearmCore

/// Architecture-review finding: the periodic time observer let a remote item's own, live duration
/// estimate unconditionally override the library's known duration — but that estimate (e.g. for a
/// Jamendo VBR MP3 served with no exact Content-Length) can be wildly wrong and keeps changing.
final class PlaybackDisplayPolicyDurationTests: XCTestCase {
    func testLibraryKnownDurationWinsOverALiveItemEstimate() {
        XCTAssertEqual(
            PlaybackDisplayPolicy.effectiveDuration(libraryKnown: 180, itemEstimate: 1260), 180,
            "a remote item's live duration estimate must never override a known library duration")
    }

    func testItemEstimateIsUsedOnlyWhenTheLibraryHasNone() {
        XCTAssertEqual(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: nil, itemEstimate: 240), 240)
        XCTAssertEqual(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: 0, itemEstimate: 240), 240)
    }

    func testNoDurationAvailableAtAllYieldsNil() {
        XCTAssertNil(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: nil, itemEstimate: nil))
        XCTAssertNil(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: 0, itemEstimate: .nan))
        XCTAssertNil(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: -5, itemEstimate: 0))
    }
}
