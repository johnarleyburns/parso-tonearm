import XCTest
@testable import TonearmCore

final class WatchPositionStoreTests: XCTestCase {

    let suite = UserDefaults(suiteName: "WatchPositionStoreTests")!

    override func setUp() {
        super.setUp()
        suite.removePersistentDomain(forName: "WatchPositionStoreTests")
    }

    func testSaveAndLoad() {
        let snapshot = WatchQueueSnapshot(trackKeys: ["a", "b"], currentIndex: 1,
                                           elapsed: 30.0, isPlaying: true)
        WatchPositionStore.save(snapshot, defaults: suite)

        let loaded = WatchPositionStore.load(defaults: suite)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.trackKeys, ["a", "b"])
        XCTAssertEqual(loaded?.currentIndex, 1)
        XCTAssertEqual(loaded?.elapsed, 30.0)
        XCTAssertTrue(loaded?.isPlaying ?? false)
    }

    func testLoadEmptyReturnsNil() {
        XCTAssertNil(WatchPositionStore.load(defaults: suite))
    }

    func testLoadOrClearHandlesCorruptData() {
        suite.set("not valid json".data(using: .utf8), forKey: "guru.parso.tonearm.watch.playback.position")
        let result = WatchPositionStore.loadOrClear(defaults: suite)
        XCTAssertNil(result, "corrupt data should return nil")
        XCTAssertNil(suite.data(forKey: "guru.parso.tonearm.watch.playback.position"),
                     "corrupt data should be cleared")
    }

    func testClearRemovesData() {
        let snapshot = WatchQueueSnapshot(trackKeys: ["x"], currentIndex: 0,
                                           elapsed: 0, isPlaying: false)
        WatchPositionStore.save(snapshot, defaults: suite)
        XCTAssertNotNil(WatchPositionStore.load(defaults: suite))

        WatchPositionStore.clear(defaults: suite)
        XCTAssertNil(WatchPositionStore.load(defaults: suite))
    }
}
