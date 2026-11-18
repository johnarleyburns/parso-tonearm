import Testing

@Suite struct WatchSettingsRedundantSectionsTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func testSettingsNoLongerShowsAudioFileTransfersOrDownloadedCollections() throws {
        let src = try source("Sources/Features/Settings/WatchSettingsView.swift")
        #expect(!src.contains("\"Audio File Transfers\""), "now redundant with My Music > On My Watch")
        #expect(!src.contains("\"Downloaded Collections\""), "now redundant with My Music > On My Watch")
        #expect(!src.contains("downloadingCard"))
        #expect(!src.contains("collectionsCard"))
    }

    @Test func testRemoveAllGuardStillReadsActivityAndCollections() throws {
        let src = try source("Sources/Features/Settings/WatchSettingsView.swift")
        #expect(src.contains("if !snapshot.collections.isEmpty || !snapshot.activity.isEmpty {"))
        #expect(src.contains("\"Remove All from Apple Watch\""))
        #expect(src.contains("enum WatchStageCopy"))
    }

    @Test func testWatchDownloadDetailViewsFileIsRemoved() {
        let path = root.appendingPathComponent("Sources/Features/Settings/WatchDownloadDetailViews.swift")
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}
