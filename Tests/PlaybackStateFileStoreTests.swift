import Testing
@testable import TonearmCore

extension SharedProductionSingletonTests {
    @Suite final class PlaybackStateFileStoreTests {
        private var tempDir: URL?

        init() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tonearm-playback-state-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            tempDir = dir
            PlaybackStateFileStore.fileURLOverride = dir.appendingPathComponent("playback-state.v2.json")
        }

        deinit {
            PlaybackStateFileStore.fileURLOverride = nil
            if let tempDir {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        @Test func testRoundTrip() throws {
            let snap = PlaybackStateSnapshot(
                trackIDs: [1, 2], trackSyncIDs: ["a", "b"],
                currentIndex: 0, elapsed: 12, isPlaying: true,
                savedAt: Date(timeIntervalSince1970: 1_000))
            PlaybackStateFileStore.save(snap)

            let loaded = try #require(PlaybackStateFileStore.load())
            #expect(loaded.trackIDs == [1, 2])
            #expect(loaded.trackSyncIDs == ["a", "b"])
            #expect(abs(loaded.elapsed - 12) <= 0.01)
            #expect(loaded.isPlaying)
        }

        @Test func testCorruptFileReturnsNilButPreservesFile() throws {
            guard let url = PlaybackStateFileStore.fileURL() else { return }
            try "not json".data(using: .utf8)!.write(to: url)

            #expect(PlaybackStateFileStore.load() == nil,
                "corrupt file must return nil, not crash")
            #expect(FileManager.default.fileExists(atPath: url.path),
                "corrupt file must be preserved for diagnosis")
        }

        @Test func testTmpFileLeftoverIsIgnored() throws {
            guard let url = PlaybackStateFileStore.fileURL() else { return }
            let tmp = url.appendingPathExtension("tmp")
            try "junk".data(using: .utf8)!.write(to: tmp)

            #expect(PlaybackStateFileStore.load() == nil,
                "tmp leftover must not be read")
        }

        @Test func testMaxSavedAtSelectionViaStore() throws {
            // Clean up any lingering file tier from other tests
            if let url = PlaybackStateFileStore.fileURL() {
                try? FileManager.default.removeItem(at: url)
            }
            let name = "test.filestore.\(UUID())"
            let suite = try #require(UserDefaults(suiteName: name))
            defer { suite.removePersistentDomain(forName: name) }

            PlaybackStateStore.defaultsProvider = { suite }
            defer { PlaybackStateStore.defaultsProvider = { PlaybackStateStore.sharedDefaults() } }

            let older = PlaybackStateSnapshot(
                trackIDs: [1], currentIndex: 0, elapsed: 5,
                isPlaying: false, savedAt: Date(timeIntervalSince1970: 100))
            let newer = PlaybackStateSnapshot(
                trackIDs: [2], currentIndex: 0, elapsed: 10,
                isPlaying: true, savedAt: Date(timeIntervalSince1970: 200))

            PlaybackStateFileStore.save(older)
            PlaybackStateStore.save(newer, defaults: suite)

            // When loading without explicit defaults → max-by-savedAt
            let loaded = PlaybackStateStore.load()
            #expect(loaded?.trackIDs == [2], "must return newer snapshot")
        }
    }
}
