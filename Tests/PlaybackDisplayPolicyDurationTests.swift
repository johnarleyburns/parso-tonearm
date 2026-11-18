import Testing
@testable import TonearmCore

/// Architecture-review finding: the periodic time observer let a remote item's own, live duration
/// estimate unconditionally override the library's known duration — but that estimate (e.g. for a
/// Jamendo VBR MP3 served with no exact Content-Length) can be wildly wrong and keeps changing.
@Suite struct PlaybackDisplayPolicyDurationTests {
    @Test func testLibraryKnownDurationWinsOverALiveItemEstimate() {
        #expect(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: 180, itemEstimate: 1260) == 180, "a remote item's live duration estimate must never override a known library duration")
    }

    @Test func testItemEstimateIsUsedOnlyWhenTheLibraryHasNone() {
        #expect(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: nil, itemEstimate: 240) == 240)
        #expect(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: 0, itemEstimate: 240) == 240)
    }

    @Test func testNoDurationAvailableAtAllYieldsNil() {
        #expect(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: nil, itemEstimate: nil) == nil)
        #expect(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: 0, itemEstimate: .nan) == nil)
        #expect(PlaybackDisplayPolicy.effectiveDuration(libraryKnown: -5, itemEstimate: 0) == nil)
    }
}
