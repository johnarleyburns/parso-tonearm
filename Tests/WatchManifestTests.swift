import Testing
@testable import TonearmCore

@Suite struct WatchManifestTests {

    @Test func testEmptyManifestStats() {
        let entries: [WatchLocalManifestEntry] = []
        #expect(WatchManifest.totalBytes(entries) == 0)
        #expect(WatchManifest.pinnedBytes(entries) == 0)
        #expect(WatchManifest.trackCount(entries) == 0)
    }

    @Test func testManifestStatsWithEntries() {
        let entries = [
            WatchLocalManifestEntry(trackKey: "t1", bytes: 1024, pinned: true),
            WatchLocalManifestEntry(trackKey: "t2", bytes: 2048, pinned: false),
            WatchLocalManifestEntry(trackKey: "t3", bytes: 512, pinned: true)
        ]
        #expect(WatchManifest.totalBytes(entries) == 3584)
        #expect(WatchManifest.pinnedBytes(entries) == 1536)
        #expect(WatchManifest.trackCount(entries) == 3)
    }
}
