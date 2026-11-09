import XCTest

final class WatchSettingsRedundantSectionsTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testSettingsNoLongerShowsAudioFileTransfersOrDownloadedCollections() throws {
        let src = try source("Sources/Features/Settings/WatchSettingsView.swift")
        XCTAssertFalse(src.contains("\"Audio File Transfers\""), "now redundant with My Music > On My Watch")
        XCTAssertFalse(src.contains("\"Downloaded Collections\""), "now redundant with My Music > On My Watch")
        XCTAssertFalse(src.contains("downloadingCard"))
        XCTAssertFalse(src.contains("collectionsCard"))
    }

    func testRemoveAllGuardStillReadsActivityAndCollections() throws {
        let src = try source("Sources/Features/Settings/WatchSettingsView.swift")
        XCTAssertTrue(src.contains("if !snapshot.collections.isEmpty || !snapshot.activity.isEmpty {"))
        XCTAssertTrue(src.contains("\"Remove All from Apple Watch\""))
        XCTAssertTrue(src.contains("enum WatchStageCopy"))
    }

    func testWatchDownloadDetailViewsFileIsRemoved() {
        let path = root.appendingPathComponent("Sources/Features/Settings/WatchDownloadDetailViews.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
}
