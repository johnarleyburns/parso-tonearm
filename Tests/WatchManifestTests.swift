import XCTest
@testable import TonearmCore

final class WatchManifestTests: XCTestCase {

    func testEmptyManifestStats() {
        let entries: [WatchLocalManifestEntry] = []
        XCTAssertEqual(WatchManifest.totalBytes(entries), 0)
        XCTAssertEqual(WatchManifest.pinnedBytes(entries), 0)
        XCTAssertEqual(WatchManifest.trackCount(entries), 0)
    }

    func testManifestStatsWithEntries() {
        let entries = [
            WatchLocalManifestEntry(trackKey: "t1", bytes: 1024, pinned: true),
            WatchLocalManifestEntry(trackKey: "t2", bytes: 2048, pinned: false),
            WatchLocalManifestEntry(trackKey: "t3", bytes: 512, pinned: true)
        ]
        XCTAssertEqual(WatchManifest.totalBytes(entries), 3584)
        XCTAssertEqual(WatchManifest.pinnedBytes(entries), 1536)
        XCTAssertEqual(WatchManifest.trackCount(entries), 3)
    }
}
