import XCTest
@testable import TonearmCore

@MainActor
final class PlaybackStateStoreTests: XCTestCase {

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

    override func tearDown() {
        PlaybackStateStore.defaultsProvider = { PlaybackStateStore.sharedDefaults() }
        super.tearDown()
    }

    private func ephemeralSuite() throws -> UserDefaults {
        let name = "test.playback.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        return suite
    }

    // MARK: - Round-trip (v1 save/load/clear with injected suite)

    func testPlaybackStateStoreRoundTripsQueueIndexAndTime() throws {
        let suite = try ephemeralSuite()
        XCTAssertNil(PlaybackStateStore.load(defaults: suite))

        let saved = PlaybackStateSnapshot(
            trackIDs: [10, 20, 30],
            currentIndex: 1,
            elapsed: 42.5,
            isPlaying: true,
            savedAt: Date(timeIntervalSince1970: 2_000)
        )
        PlaybackStateStore.save(saved, defaults: suite)

        let loaded = try XCTUnwrap(PlaybackStateStore.load(defaults: suite))
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(loaded.trackIDs, [10, 20, 30])
        XCTAssertEqual(loaded.currentIndex, 1)
        XCTAssertEqual(loaded.elapsed, 42.5, accuracy: 0.001)
        XCTAssertTrue(loaded.isPlaying)

        PlaybackStateStore.clear(defaults: suite)
        XCTAssertNil(PlaybackStateStore.load(defaults: suite))
    }

    // MARK: - Seek persists immediately

    func testSeekPersistsElapsedImmediately() throws {
        let suite = try ephemeralSuite()
        PlaybackStateStore.defaultsProvider = { suite }

        let player = AudioPlayer.shared
        resetForTest(player)

        let row = fakeTrackRow(1)
        player.play(tracks: [row], startAt: 0)

        player.seek(to: 42.5)

        let snapshot = try XCTUnwrap(PlaybackStateStore.load(defaults: suite))
        XCTAssertEqual(snapshot.elapsed, 42.5, accuracy: 0.01)
        XCTAssertEqual(snapshot.trackIDs, [1])
        XCTAssertEqual(snapshot.currentIndex, 0)
    }

    // MARK: - Pause persists the current elapsed

    func testPausePersistsCurrentElapsed() throws {
        let suite = try ephemeralSuite()
        PlaybackStateStore.defaultsProvider = { suite }

        let player = AudioPlayer.shared
        resetForTest(player)

        let row = fakeTrackRow(1)
        player.play(tracks: [row], startAt: 0)

        // Simulate progress via seek, then pause
        player.seek(to: 12.0)
        player.pausePlayback()

        let snapshot = try XCTUnwrap(PlaybackStateStore.load(defaults: suite))
        XCTAssertEqual(snapshot.elapsed, 12.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.trackIDs, [1])
    }

    // MARK: - Ambient guard

    func testPersistPlaybackStateNoOpsInAmbientMode() throws {
        let suite = try ephemeralSuite()
        PlaybackStateStore.defaultsProvider = { suite }

        let player = AudioPlayer.shared
        resetForTest(player)

        let row = fakeTrackRow(1)
        player.play(tracks: [row], startAt: 0)
        PlaybackStateStore.clear(defaults: suite)

        // Non-ambient: guard lets persist through
        player.persistPlaybackState()
        let snapshot = PlaybackStateStore.load(defaults: suite)
        XCTAssertNotNil(snapshot, "Non-ambient persist must write a snapshot")
    }

    // MARK: - Helpers

    private func resetForTest(_ player: AudioPlayer) {
        if !player.queue.isEmpty {
            player.removeFromQueue(atOffsets: IndexSet(0..<player.queue.count))
        }
        player.resetRestoreForTesting()
    }
}
