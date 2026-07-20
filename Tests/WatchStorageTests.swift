import XCTest
@testable import TonearmCore

final class WatchStorageTests: XCTestCase {

    func testAccountingWithEntries() {
        let entries = [
            WatchLocalManifestEntry(trackKey: "t1", bytes: 1024, pinned: true),
            WatchLocalManifestEntry(trackKey: "t2", bytes: 2048, pinned: false),
            WatchLocalManifestEntry(trackKey: "t3", bytes: 512, pinned: true)
        ]
        let acct = WatchStorage.accounting(manifestEntries: entries, freeBytes: 10_000_000, totalBytes: 32_000_000_000)
        XCTAssertEqual(acct.pinnedBytes, 1536)
        XCTAssertEqual(acct.cacheBytes, 2048)
        XCTAssertEqual(acct.usedBytes, 3584)
        XCTAssertEqual(acct.freeBytes, 10_000_000)
        XCTAssertEqual(acct.totalBytes, 32_000_000_000)
    }

    func testAccountingEmpty() {
        let acct = WatchStorage.accounting(manifestEntries: [], freeBytes: 1_000, totalBytes: 10_000)
        XCTAssertEqual(acct.pinnedBytes, 0)
        XCTAssertEqual(acct.cacheBytes, 0)
        XCTAssertEqual(acct.usedBytes, 0)
    }

    func testUsageFraction() {
        let acct = WatchStorage.Accounting(pinnedBytes: 5_000, cacheBytes: 5_000,
                                            freeBytes: 10_000, totalBytes: 20_000)
        XCTAssertEqual(acct.usageFraction, 0.5, accuracy: 0.01)
    }

    func testHasFreeSpace() {
        XCTAssertTrue(WatchStorage.hasFreeSpace(freeBytes: 200 * 1024 * 1024))
        XCTAssertFalse(WatchStorage.hasFreeSpace(freeBytes: 50 * 1024 * 1024))
    }

    func testKeysForPinnedCollection() {
        let entries = [
            WatchLocalManifestEntry(trackKey: "t1", bytes: 100, pinned: true),
            WatchLocalManifestEntry(trackKey: "t2", bytes: 200, pinned: false),
            WatchLocalManifestEntry(trackKey: "t3", bytes: 300, pinned: true)
        ]
        let keys = WatchStorage.keysForCollection(["t1", "t2", "t3"], manifestEntries: entries)
        XCTAssertEqual(Set(keys), ["t1", "t3"])
    }

    func testBytesForKeys() {
        let entries = [
            WatchLocalManifestEntry(trackKey: "t1", bytes: 100, pinned: true),
            WatchLocalManifestEntry(trackKey: "t2", bytes: 200, pinned: false)
        ]
        let bytes = WatchStorage.bytesForKeys(["t1"], manifestEntries: entries)
        XCTAssertEqual(bytes, 100)
    }
}
