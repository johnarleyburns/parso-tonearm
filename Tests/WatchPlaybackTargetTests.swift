import XCTest
@testable import TonearmWatchCore

/// Phase 9c — the explicit playback target and its persistence (§7.1: "defaults to the last
/// explicit target, initially iPhone").
final class WatchPlaybackTargetTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "WatchPlaybackTargetTests-\(UUID().uuidString)")!
        return d
    }

    func testDefaultsToIPhoneWhenNothingStored() {
        XCTAssertEqual(WatchPlaybackTargetStore.load(defaults: makeDefaults()), .iPhone)
    }

    func testRoundTrips() {
        let d = makeDefaults()
        WatchPlaybackTargetStore.save(.thisWatch, defaults: d)
        XCTAssertEqual(WatchPlaybackTargetStore.load(defaults: d), .thisWatch)
        WatchPlaybackTargetStore.save(.iPhone, defaults: d)
        XCTAssertEqual(WatchPlaybackTargetStore.load(defaults: d), .iPhone)
    }

    func testUnrecognisedStoredValueFallsBackToIPhone() {
        let d = makeDefaults()
        d.set("appleTV", forKey: "guru.parso.tonearm.watch.playback.target")
        XCTAssertEqual(WatchPlaybackTargetStore.load(defaults: d), .iPhone)
    }

    func testClearResetsToDefault() {
        let d = makeDefaults()
        WatchPlaybackTargetStore.save(.thisWatch, defaults: d)
        WatchPlaybackTargetStore.clear(defaults: d)
        XCTAssertEqual(WatchPlaybackTargetStore.load(defaults: d), .iPhone)
    }

    func testOtherIsTheOppositeTarget() {
        XCTAssertEqual(WatchPlaybackTarget.iPhone.other, .thisWatch)
        XCTAssertEqual(WatchPlaybackTarget.thisWatch.other, .iPhone)
    }
}
