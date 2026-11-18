import Testing
@testable import TonearmCore

@Suite struct WatchStorageTests {

    @Test func testAccountingWithEntries() {
        let entries = [
            WatchLocalManifestEntry(trackKey: "t1", bytes: 1024, pinned: true),
            WatchLocalManifestEntry(trackKey: "t2", bytes: 2048, pinned: false),
            WatchLocalManifestEntry(trackKey: "t3", bytes: 512, pinned: true)
        ]
        let acct = WatchStorage.accounting(manifestEntries: entries, freeBytes: 10_000_000, totalBytes: 32_000_000_000)
        #expect(acct.pinnedBytes == 1536)
        #expect(acct.cacheBytes == 2048)
        #expect(acct.usedBytes == 3584)
        #expect(acct.freeBytes == 10_000_000)
        #expect(acct.totalBytes == 32_000_000_000)
    }

    @Test func testAccountingEmpty() {
        let acct = WatchStorage.accounting(manifestEntries: [], freeBytes: 1_000, totalBytes: 10_000)
        #expect(acct.pinnedBytes == 0)
        #expect(acct.cacheBytes == 0)
        #expect(acct.usedBytes == 0)
    }

    @Test func testUsageFraction() {
        let acct = WatchStorage.Accounting(pinnedBytes: 5_000, cacheBytes: 5_000,
                                            freeBytes: 10_000, totalBytes: 20_000)
        #expect(abs(acct.usageFraction - 0.5) <= 0.01)
    }

    @Test func testHasFreeSpace() {
        #expect(WatchStorage.hasFreeSpace(freeBytes: 200 * 1024 * 1024))
        #expect(!WatchStorage.hasFreeSpace(freeBytes: 50 * 1024 * 1024))
    }

    @Test func testKeysForPinnedCollection() {
        let entries = [
            WatchLocalManifestEntry(trackKey: "t1", bytes: 100, pinned: true),
            WatchLocalManifestEntry(trackKey: "t2", bytes: 200, pinned: false),
            WatchLocalManifestEntry(trackKey: "t3", bytes: 300, pinned: true)
        ]
        let keys = WatchStorage.keysForCollection(["t1", "t2", "t3"], manifestEntries: entries)
        #expect(Set(keys) == ["t1", "t3"])
    }

    @Test func testBytesForKeys() {
        let entries = [
            WatchLocalManifestEntry(trackKey: "t1", bytes: 100, pinned: true),
            WatchLocalManifestEntry(trackKey: "t2", bytes: 200, pinned: false)
        ]
        let bytes = WatchStorage.bytesForKeys(["t1"], manifestEntries: entries)
        #expect(bytes == 100)
    }
}
