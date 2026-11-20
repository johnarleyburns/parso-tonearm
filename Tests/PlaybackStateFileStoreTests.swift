import Foundation
import Testing
@testable import TonearmCore

extension SharedProductionSingletonTests {
    /// Drives `PlaybackStateFileStore` directly. Each test owns its own
    /// temporary file, passed explicitly, so nothing here touches the
    /// process-wide App Support location and the suite needs no serialization.
    @MainActor
    @Suite final class PlaybackStateFileStoreTests {
        private func tempFileURL() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("tonearm-playback-state-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("playback-state.v2.json")
        }

        private func removeParent(of url: URL) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        @Test func testRoundTrip() throws {
            let url = tempFileURL()
            defer { removeParent(of: url) }

            let snap = PlaybackStateSnapshot(
                trackIDs: [1, 2], trackSyncIDs: ["a", "b"],
                currentIndex: 0, elapsed: 12, isPlaying: true,
                savedAt: Date(timeIntervalSince1970: 1_000))
            PlaybackStateFileStore.save(snap, to: url)

            let loaded = try #require(PlaybackStateFileStore.load(from: url))
            #expect(loaded.trackIDs == [1, 2])
            #expect(loaded.trackSyncIDs == ["a", "b"])
            #expect(abs(loaded.elapsed - 12) <= 0.01)
            #expect(loaded.isPlaying)
        }

        @Test func testCorruptFileReturnsNilButPreservesFile() throws {
            let url = tempFileURL()
            defer { removeParent(of: url) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "not json".data(using: .utf8)!.write(to: url)

            #expect(PlaybackStateFileStore.load(from: url) == nil,
                "corrupt file must return nil, not crash")
            #expect(FileManager.default.fileExists(atPath: url.path),
                "corrupt file must be preserved for diagnosis")
        }

        @Test func testTmpFileLeftoverIsIgnored() throws {
            let url = tempFileURL()
            defer { removeParent(of: url) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let tmp = url.appendingPathExtension("tmp")
            try "junk".data(using: .utf8)!.write(to: tmp)

            #expect(PlaybackStateFileStore.load(from: url) == nil,
                "tmp leftover must not be read")
        }

        @Test func testMaxSavedAtSelectionViaStore() throws {
            let url = tempFileURL()
            defer { removeParent(of: url) }
            let defaults = InMemoryDefaultsStore()
            let persistence = CompositePlaybackStatePersistence(defaults: defaults, fileURL: url)

            let older = PlaybackStateSnapshot(
                trackIDs: [1], currentIndex: 0, elapsed: 5,
                isPlaying: false, savedAt: Date(timeIntervalSince1970: 100))
            let newer = PlaybackStateSnapshot(
                trackIDs: [2], currentIndex: 0, elapsed: 10,
                isPlaying: true, savedAt: Date(timeIntervalSince1970: 200))

            // Older in the file tier, newer in the defaults tier.
            PlaybackStateFileStore.save(older, to: url)
            PlaybackStateStore.save(newer, defaults: defaults)

            let loaded = persistence.load()
            #expect(loaded?.trackIDs == [2], "must return newer snapshot")
        }
    }
}
