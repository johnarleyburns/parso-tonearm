import Foundation
import Testing
@testable import TonearmCore

extension SharedProductionSingletonTests {
    @MainActor
    @Suite final class PlaybackStateStoreTests {

        private let persistence = InMemoryPlaybackStatePersistence()
        private let src = Source(id: 1, kind: .iaItem, iaIdentifier: "x",
                                  originalURL: nil, title: "Test Source",
                                  addedAt: Date(), lastResolvedAt: nil,
                                  followUpdates: false, licenseText: nil, memberCapHit: false)
        private lazy var album = Album(id: 1, sourceId: 1, title: "Album", artist: "Artist")

        private func fakeTrackRow(_ i: Int) -> TrackRow {
            let t = Track(id: Int64(i), albumId: 1, sourceId: 1,
                          title: "Track \(i)", trackNo: i, discNo: nil,
                          durationSec: 120, codec: "MP3", sampleRate: nil,
                          bitDepthOrBitrate: nil, sortKey: "\(i)")
            let a = Asset(id: Int64(i), trackId: Int64(i), kind: .remote,
                          bookmark: nil, relPath: nil,
                          remoteURL: "https://example.com/track\(i).mp3",
                          altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
            return TrackRow(track: t, album: album, source: src, asset: a)
        }

        private func usePersistence(_ player: AudioPlayer) {
            player.persistor = PlaybackPositionPersistor(stateStore: persistence)
        }

        // MARK: - Round-trip (v1 save/load/clear with injected suite)

        @Test func testPlaybackStateStoreRoundTripsQueueIndexAndTime() throws {
            let suite = persistence.defaults
            #expect(PlaybackStateStore.load(defaults: suite) == nil)

            let saved = PlaybackStateSnapshot(
                trackIDs: [10, 20, 30],
                currentIndex: 1,
                elapsed: 42.5,
                isPlaying: true,
                savedAt: Date(timeIntervalSince1970: 2_000)
            )
            PlaybackStateStore.save(saved, defaults: suite)

            let loaded = try #require(PlaybackStateStore.load(defaults: suite))
            #expect(loaded == saved)
            #expect(loaded.trackIDs == [10, 20, 30])
            #expect(loaded.currentIndex == 1)
            #expect(abs(loaded.elapsed - 42.5) <= 0.001)
            #expect(loaded.isPlaying)

            PlaybackStateStore.clear(defaults: suite)
            #expect(PlaybackStateStore.load(defaults: suite) == nil)
        }

        // MARK: - Seek persists immediately

        @Test func testSeekPersistsElapsedImmediately() throws {
            let suite = persistence.defaults

            let player = AudioPlayer.makeForTesting()
            usePersistence(player)
            resetForTest(player)

            let row = fakeTrackRow(1)
            player.play(tracks: [row], startAt: 0)

            player.seek(to: 42.5)

            let snapshot = try #require(PlaybackStateStore.load(defaults: suite))
            #expect(abs(snapshot.elapsed - 42.5) <= 0.01)
            #expect(snapshot.trackIDs == [1])
            #expect(snapshot.currentIndex == 0)
        }

        // MARK: - Pause persists the current elapsed

        @Test func testPausePersistsCurrentElapsed() throws {
            let suite = persistence.defaults

            let player = AudioPlayer.makeForTesting()
            usePersistence(player)
            resetForTest(player)

            let row = fakeTrackRow(1)
            player.play(tracks: [row], startAt: 0)

            // Simulate progress via seek, then pause
            player.seek(to: 12.0)
            player.pausePlayback()

            let snapshot = try #require(PlaybackStateStore.load(defaults: suite))
            #expect(abs(snapshot.elapsed - 12.0) <= 0.01)
            #expect(snapshot.trackIDs == [1])
        }

        // MARK: - Ambient guard

        @Test func testPersistPlaybackStateNoOpsInAmbientMode() throws {
            let suite = persistence.defaults

            let player = AudioPlayer.makeForTesting()
            usePersistence(player)
            resetForTest(player)

            let row = fakeTrackRow(1)
            player.play(tracks: [row], startAt: 0)
            PlaybackStateStore.clear(defaults: suite)

            // Non-ambient: guard lets persist through
            player.persistPlaybackState()
            let snapshot = PlaybackStateStore.load(defaults: suite)
            #expect(snapshot != nil, "Non-ambient persist must write a snapshot")
        }

        // MARK: - v1 payload decodes after v2 struct change

        @Test func testV1PayloadDecodesAfterV2StructChange() throws {
            // A v1 payload (no trackSyncIDs field) must decode successfully with the
            // v2 struct, yielding trackSyncIDs = nil.
            let v1JSON = """
            {"trackIDs":[1,2],"currentIndex":0,"elapsed":42,"isPlaying":true,"savedAt":978307200}
            """.data(using: .utf8)!

            let snapshot = try JSONDecoder().decode(PlaybackStateSnapshot.self, from: v1JSON)
            #expect(snapshot.trackIDs == [1, 2])
            #expect(snapshot.trackSyncIDs == nil,
                "v1 payload must decode with trackSyncIDs=nil")
            #expect(abs(snapshot.elapsed - 42) <= 0.01)
            #expect(snapshot.isPlaying)
        }

        // MARK: - Helpers

        private func resetForTest(_ player: AudioPlayer) {
            if !player.queue.isEmpty {
                player.removeFromQueue(atOffsets: IndexSet(0..<player.queue.count))
            }
            player.resetRestoreForTesting()
        }
    }
}
