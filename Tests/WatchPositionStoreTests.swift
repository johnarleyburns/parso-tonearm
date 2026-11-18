import Testing
@testable import TonearmCore

@Suite struct WatchPositionStoreTests {

    let suite = UserDefaults(suiteName: "WatchPositionStoreTests")!

    init() {
        suite.removePersistentDomain(forName: "WatchPositionStoreTests")
    }

    @Test func testSaveAndLoad() {
        let snapshot = WatchQueueSnapshot(trackKeys: ["a", "b"], currentIndex: 1,
                                           elapsed: 30.0, isPlaying: true)
        WatchPositionStore.save(snapshot, defaults: suite)

        let loaded = WatchPositionStore.load(defaults: suite)
        #expect(loaded != nil)
        #expect(loaded?.trackKeys == ["a", "b"])
        #expect(loaded?.currentIndex == 1)
        #expect(loaded?.elapsed == 30.0)
        #expect(loaded?.isPlaying ?? false)
    }

    @Test func testLoadEmptyReturnsNil() {
        #expect(WatchPositionStore.load(defaults: suite) == nil)
    }

    @Test func testLoadOrClearHandlesCorruptData() {
        suite.set("not valid json".data(using: .utf8), forKey: "guru.parso.tonearm.watch.playback.position")
        let result = WatchPositionStore.loadOrClear(defaults: suite)
        #expect(result == nil, "corrupt data should return nil")
        #expect(suite.data(forKey: "guru.parso.tonearm.watch.playback.position") == nil,
                     "corrupt data should be cleared")
    }

    @Test func testClearRemovesData() {
        let snapshot = WatchQueueSnapshot(trackKeys: ["x"], currentIndex: 0,
                                           elapsed: 0, isPlaying: false)
        WatchPositionStore.save(snapshot, defaults: suite)
        #expect(WatchPositionStore.load(defaults: suite) != nil)

        WatchPositionStore.clear(defaults: suite)
        #expect(WatchPositionStore.load(defaults: suite) == nil)
    }
}
