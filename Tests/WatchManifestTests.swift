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

    func testReportGeneration() {
        let entries = [
            WatchLocalManifestEntry(trackKey: "t1", bytes: 500, pinned: true),
            WatchLocalManifestEntry(trackKey: "t2", bytes: 300, pinned: false)
        ]
        let report = WatchManifest.report(from: entries, freeBytes: 1_000_000, catalogVersion: 7)

        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.freeBytes, 1_000_000)
        XCTAssertEqual(report.catalogVersion, 7)
        XCTAssertTrue(report.entries[0].pinned)
        XCTAssertFalse(report.entries[1].pinned)
    }
}
