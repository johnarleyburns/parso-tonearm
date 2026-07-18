import XCTest
import AVFoundation
@testable import TonearmCore

final class SpyingUserDefaults: UserDefaults {
    private static let stateKey = "guru.parso.tonearm.playback.state.v1"
    private(set) var recordedSnapshots: [PlaybackStateSnapshot] = []
    let suiteName: String

    init?(suiteName: String) {
        self.suiteName = suiteName
        super.init(suiteName: suiteName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        guard defaultName == Self.stateKey,
              let data = value as? Data,
              let snapshot = try? JSONDecoder().decode(PlaybackStateSnapshot.self, from: data)
        else { return }
        recordedSnapshots.append(snapshot)
    }

    func clearRecorded() { recordedSnapshots.removeAll() }
}

@MainActor
final class PlaybackPositionLossTests: XCTestCase {

    private var createdSuites: [String] = []

    private func ephemeralSuite() throws -> UserDefaults {
        let name = "test.loss.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        createdSuites.append(name)
        return suite
    }

    override func tearDown() {
        PlaybackStateStore.defaultsProvider = { PlaybackStateStore.sharedDefaults() }
        for name in createdSuites {
            UserDefaults().removePersistentDomain(forName: name)
        }
        createdSuites.removeAll()
        let player = AudioPlayer.shared
        if !player.queue.isEmpty {
            player.removeFromQueue(atOffsets: IndexSet(0..<player.queue.count))
        }
        player.resetRestoreForTesting()
        super.tearDown()
    }

    private func resetPlayer(_ player: AudioPlayer) {
        if !player.queue.isEmpty {
            player.removeFromQueue(atOffsets: IndexSet(0..<player.queue.count))
        }
        player.resetRestoreForTesting()
    }

    @discardableResult
    private func createTestWAV(duration: TimeInterval = 4.0) throws -> String {
        let relDir = "Tonearm/test"
        let filename = "loss_test_tone_\(UUID().uuidString.prefix(8)).wav"
        let relPath = "\(relDir)/\(filename)"

        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent(relDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)

        let sampleRate: Double = 44100
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1)
        else { throw TestError.noAudioFormat }

        let frames = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { throw TestError.noAudioBuffer }
        buffer.frameLength = frames

        if let ptr = buffer.floatChannelData?.pointee {
            for i in 0..<Int(frames) {
                ptr[i] = Float(sin(2 * .pi * 440 * Double(i) / sampleRate) * 0.5)
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return relPath
    }

    /// Inserts Source + Album + Track + Asset into the shared DB. Uses random
    /// high IDs to avoid unique-constraint collisions across repeated runs.
    /// Returns the hydrated TrackRow and its track id.
    private func insertTestTrack(relPath: String) async throws -> (row: TrackRow, id: Int64) {
        let trackId = Int64.random(in: 10_000_000...99_999_999)
        let store = LibraryStore.shared
        let src = Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                         title: "PosTestSrc-\(UUID().uuidString.prefix(6))",
                         addedAt: Date(), lastResolvedAt: nil,
                         followUpdates: false, licenseText: nil, memberCapHit: false)
        let insertedSrc = try await store.insertSource(src)
        guard let sourceId = insertedSrc.id else { throw TestError.noID }

        let album = Album(id: nil, sourceId: sourceId, title: "PosTestAlbum-\(UUID().uuidString.prefix(6))",
                          artist: "PosTestArtist")
        let insertedAlbum = try await store.insertAlbum(album)
        guard let albumId = insertedAlbum.id else { throw TestError.noID }

        let track = Track(id: trackId, albumId: albumId, sourceId: sourceId,
                          title: "PosTestTrack", trackNo: 1, discNo: nil,
                          durationSec: 240, codec: "WAV", sampleRate: 44100,
                          bitDepthOrBitrate: nil, sortKey: "PosTest-\(trackId)")
        let insertedTrack = try await store.insertTrack(track)
        guard let insertedTrackId = insertedTrack.id else { throw TestError.noID }

        let asset = Asset(id: nil, trackId: insertedTrackId, kind: .localRef,
                          bookmark: nil, relPath: relPath,
                          remoteURL: nil, altRemoteURL: nil, sizeBytes: nil,
                          unsupportedReason: nil)
        _ = try await store.insertAsset(asset)

        let row = TrackRow(track: insertedTrack, album: insertedAlbum,
                           source: insertedSrc, asset: asset)
        return (row, trackId)
    }

    // MARK: - Test 1: Playing tick does NOT persist elapsed (Loss #1)

    func testPlayingTickDoesNotPersistElapsed_FORCEQUIT_BUG() throws {
        let suite = try ephemeralSuite()
        PlaybackStateStore.defaultsProvider = { suite }

        let player = AudioPlayer.shared
        resetPlayer(player)

        let relPath = try createTestWAV(duration: 4.0)
        let asset = Asset(id: 9, trackId: 9, kind: .localRef,
                          bookmark: nil, relPath: relPath,
                          remoteURL: nil, altRemoteURL: nil, sizeBytes: nil,
                          unsupportedReason: nil)
        let row = TrackRow(
            track: Track(id: 9, albumId: nil, sourceId: 1,
                         title: "Tone", trackNo: 1, discNo: nil,
                         durationSec: 4.0, codec: "WAV", sampleRate: 44100,
                         bitDepthOrBitrate: nil, sortKey: "Tone"),
            album: nil, source: nil, asset: asset)

        PlaybackStateStore.clear(defaults: suite)
        player.play(tracks: [row], startAt: 0)

        let advanced = pollUntil(keyPath: \AudioPlayer.currentTime,
                                 greaterThan: 1.5, on: player, timeout: 10.0)
        if !advanced {
            throw XCTSkip("host cannot play audio (currentTime never advanced)")
        }

        XCTExpectFailure("Loss #1: periodic tick never persists; fixed by F3", strict: true) {
            let snapshot = PlaybackStateStore.load(defaults: suite)
            XCTAssertNotNil(snapshot, "snapshot should be present")
            if let snap = snapshot {
                XCTAssertGreaterThanOrEqual(snap.elapsed, 1.0,
                    "tick must persist elapsed >= 1.0; found \(snap.elapsed)")
            }
        }
    }

    // MARK: - Tests 2–4: Control surfaces on empty queue (Loss #2)

    func testResumeOnEmptyQueuePreservesSnapshot() throws {
        let suite = try ephemeralSuite()
        PlaybackStateStore.defaultsProvider = { suite }
        resetPlayer(AudioPlayer.shared)

        PlaybackStateStore.save(PlaybackStateSnapshot(
            trackIDs: [1, 2, 3], currentIndex: 1, elapsed: 30,
            isPlaying: false, savedAt: Date()), defaults: suite)

        AudioPlayer.shared.resumePlayback()

        let snap = PlaybackStateStore.load(defaults: suite)
        XCTAssertNotNil(snap, "snapshot must survive resume on empty queue")
    }

    func testPauseOnEmptyQueuePreservesSnapshot() throws {
        let suite = try ephemeralSuite()
        PlaybackStateStore.defaultsProvider = { suite }
        resetPlayer(AudioPlayer.shared)

        PlaybackStateStore.save(PlaybackStateSnapshot(
            trackIDs: [1, 2, 3], currentIndex: 1, elapsed: 30,
            isPlaying: false, savedAt: Date()), defaults: suite)

        AudioPlayer.shared.pausePlayback()

        let snap = PlaybackStateStore.load(defaults: suite)
        XCTAssertNotNil(snap, "snapshot must survive pause on empty queue")
    }

    func testTogglePlayPauseOnEmptyQueuePreservesSnapshot() throws {
        let suite = try ephemeralSuite()
        PlaybackStateStore.defaultsProvider = { suite }
        resetPlayer(AudioPlayer.shared)

        PlaybackStateStore.save(PlaybackStateSnapshot(
            trackIDs: [1, 2, 3], currentIndex: 1, elapsed: 30,
            isPlaying: false, savedAt: Date()), defaults: suite)

        AudioPlayer.shared.togglePlayPause()

        let snap = PlaybackStateStore.load(defaults: suite)
        XCTAssertNotNil(snap, "snapshot must survive toggle on empty queue")
    }

    // MARK: - Test 5: Restore never writes regressed elapsed (Loss #3)

    func testRestoreNeverWritesRegressedElapsed() async throws {
        let relPath = try createTestWAV(duration: 4.0)
        let (_, trackId) = try await insertTestTrack(relPath: relPath)

        guard let spySuite = SpyingUserDefaults(suiteName: "spy.loss5.\(UUID().uuidString)") else {
            XCTFail("could not create spy suite"); return
        }
        defer { spySuite.removePersistentDomain(forName: spySuite.suiteName) }
        PlaybackStateStore.defaultsProvider = { spySuite }

        let player = AudioPlayer.shared
        resetPlayer(player)

        let seed = PlaybackStateSnapshot(
            trackIDs: [trackId], currentIndex: 0, elapsed: 190,
            isPlaying: false, savedAt: Date())
        PlaybackStateStore.save(seed, defaults: spySuite)
        spySuite.clearRecorded()

        player.resetRestoreForTesting()
        await player.restorePersistedQueue()

        let regressed = spySuite.recordedSnapshots.filter {
            $0.trackIDs == [trackId] && $0.elapsed < 190
        }

        XCTAssertTrue(regressed.isEmpty,
            "restore must not write regressed elapsed; found \(regressed.map(\.elapsed))")
    }

    // MARK: - Test 6: Restore with missing current track (Loss #5)

    func testRestoreWithMissingCurrentTrackDoesNotApplyElapsedToWrongTrack() async throws {
        let relPath = try createTestWAV(duration: 4.0)
        let (_, realId) = try await insertTestTrack(relPath: relPath)

        let suite = try ephemeralSuite()
        PlaybackStateStore.defaultsProvider = { suite }

        let player = AudioPlayer.shared
        resetPlayer(player)

        PlaybackStateStore.save(PlaybackStateSnapshot(
            trackIDs: [999999, realId], currentIndex: 0, elapsed: 100,
            isPlaying: false, savedAt: Date()), defaults: suite)

        player.resetRestoreForTesting()
        await player.restorePersistedQueue()

        XCTAssertEqual(player.currentTime, 0, accuracy: 0.01,
            "elapsed must be 0 when saved current track is missing")
    }

    // MARK: - Test 7: Snapshot survives reinstall (Loss #4) — F8 proof

    func testSnapshotSurvivesReinstall() async throws {
        let fakeCloud = FakePlaybackCloudBackend()
        let persistor = PlaybackPositionPersistor(cloudBackend: fakeCloud)

        let snapshot = PlaybackStateSnapshot(
            trackIDs: [77], trackSyncIDs: ["cloud-sync-id-777"],
            currentIndex: 0, elapsed: 55.5, isPlaying: false, savedAt: Date())

        // Save through persistor: admission + composite store (file + defaults + cloud).
        persistor.save(candidate: snapshot, reason: .userSeek)

        // Simulate uninstall: wipe file + defaults tiers.
        PlaybackStateStore.clear()
        if let url = PlaybackStateFileStore.fileURL() {
            try? FileManager.default.removeItem(at: url)
        }

        // Cloud tier must retain the snapshot.
        let cloudSnapshot = await fakeCloud.load()
        XCTAssertNotNil(cloudSnapshot, "cloud tier must retain snapshot after local wipe")
        let cs = try XCTUnwrap(cloudSnapshot)
        XCTAssertEqual(cs.elapsed, 55.5, accuracy: 0.01,
            "cloud snapshot must match saved elapsed")
        XCTAssertEqual(cs.trackSyncIDs, ["cloud-sync-id-777"],
            "identity must be by syncID after reinstall")

        // loadBest from persistor returns cloud snapshot when local tiers are gone.
        let loaded = await persistor.loadBest()
        XCTAssertNotNil(loaded, "loadBest must return snapshot from cloud when local is wiped")
        XCTAssertEqual(loaded?.trackSyncIDs, ["cloud-sync-id-777"],
            "syncID identity must survive reinstall")
    }

    // MARK: - Test 8: Snapshot stores stable track identity (F1)

    func testSnapshotStoresStableTrackIdentity() throws {
        let suite = try ephemeralSuite()
        PlaybackStateStore.defaultsProvider = { suite }

        let player = AudioPlayer.shared
        resetPlayer(player)

        let row = TrackRow(
            track: Track(id: 99, albumId: nil, sourceId: 1,
                         title: "SyncID Track", trackNo: 1, discNo: nil,
                         durationSec: 120, codec: "MP3", sampleRate: nil,
                         bitDepthOrBitrate: nil, sortKey: "SyncID",
                         syncID: "sync-test-abc-123"),
            album: nil, source: nil, asset: Asset(id: 99, trackId: 99, kind: .remote,
                                                   bookmark: nil, relPath: nil,
                                                   remoteURL: "https://example.com/t.mp3",
                                                   altRemoteURL: nil, sizeBytes: nil,
                                                   unsupportedReason: nil))

        player.play(tracks: [row], startAt: 0)

        // Direct persist so trackSyncIDs are populated
        player.persistPlaybackState()

        let snapshot = PlaybackStateStore.load(defaults: suite)
        XCTAssertNotNil(snapshot, "snapshot must be saved")
        XCTAssertEqual(snapshot?.trackSyncIDs, ["sync-test-abc-123"],
            "trackSyncIDs must be populated from the queued track's syncID")
    }
}

// MARK: - Poll helper

private func pollUntil<Object: AnyObject, Value: Comparable>(
    keyPath: KeyPath<Object, Value>,
    greaterThan threshold: Value,
    on object: Object,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if object[keyPath: keyPath] > threshold {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}

private enum TestError: Error {
    case noAudioFormat
    case noAudioBuffer
    case noID
}
