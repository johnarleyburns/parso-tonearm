import Foundation
import Testing
import AVFoundation
@testable import TonearmCore

extension SharedProductionSingletonTests {
    @MainActor
    @Suite final class PlaybackPositionLossTests {
        private let player = AudioPlayer.makeForTesting()
        private let persistence = InMemoryPlaybackStatePersistence()

        /// Points the player's persistence funnel at this test's in-memory
        /// store; no real defaults domain or App Support file is involved.
        private func usePersistence() {
            player.persistor = PlaybackPositionPersistor(stateStore: persistence)
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

        // MARK: - Test 1: A current-time tick persists a crash-resume checkpoint

        @Test func testPlaybackTickPersistsElapsedEvenWhenTransportStateLags() throws {
            let suite = persistence.defaults
            usePersistence()

            resetPlayer(player)
            let row = TrackRow(
                track: Track(id: 9, albumId: nil, sourceId: 1,
                             title: "Tone", trackNo: 1, discNo: nil,
                             durationSec: 4.0, codec: "WAV", sampleRate: 44100,
                             bitDepthOrBitrate: nil, sortKey: "Tone"),
                album: nil, source: nil, asset: nil)

            // Drive the same seam used by AVPlayer's periodic observer without
            // relying on host audio hardware.  In the old implementation this
            // was a red test because persistTick returned while isAdvancing was
            // false, losing the last checkpoint during a state transition.
            PlaybackStateStore.clear(defaults: suite)
            player.queue = [row]
            player.index = 0
            player.currentTime = 2.25
            player.isPlaying = false
            player.persistTick()

            let snapshot = PlaybackStateStore.load(defaults: suite)
            #expect(snapshot != nil, "a tick must create a durable checkpoint")
            #expect(snapshot?.trackIDs == [9])
            #expect(abs((snapshot?.elapsed ?? 0) - 2.25) <= 0.01)
        }

        @Test func testPlaybackCheckpointIsWrittenOnBackgroundEvenWhenPaused() throws {
            let suite = persistence.defaults
            usePersistence()
            resetPlayer(player)
            player.queue = [TrackRow(
                track: Track(id: 10, albumId: nil, sourceId: 1, title: "Paused",
                             trackNo: 1, discNo: nil, durationSec: 90, codec: "WAV",
                             sampleRate: 44100, bitDepthOrBitrate: nil, sortKey: "Paused"),
                album: nil, source: nil, asset: nil)]
            player.index = 0
            player.currentTime = 17.5
            player.isPlaying = false
            player.persistNow()

            #expect(abs((PlaybackStateStore.load(defaults: suite)?.elapsed ?? 0) - 17.5) <= 0.01)
        }

        // MARK: - Tests 2–4: Control surfaces on empty queue (Loss #2)

        @Test func testResumeOnEmptyQueuePreservesSnapshot() throws {
            let suite = persistence.defaults
            usePersistence()
            resetPlayer(player)

            PlaybackStateStore.save(PlaybackStateSnapshot(
                trackIDs: [1, 2, 3], currentIndex: 1, elapsed: 30,
                isPlaying: false, savedAt: Date()), defaults: suite)

            player.resumePlayback()

            let snap = PlaybackStateStore.load(defaults: suite)
            #expect(snap != nil, "snapshot must survive resume on empty queue")
        }

        @Test func testPauseOnEmptyQueuePreservesSnapshot() throws {
            let suite = persistence.defaults
            usePersistence()
            resetPlayer(player)

            PlaybackStateStore.save(PlaybackStateSnapshot(
                trackIDs: [1, 2, 3], currentIndex: 1, elapsed: 30,
                isPlaying: false, savedAt: Date()), defaults: suite)

            player.pausePlayback()

            let snap = PlaybackStateStore.load(defaults: suite)
            #expect(snap != nil, "snapshot must survive pause on empty queue")
        }

        @Test func testTogglePlayPauseOnEmptyQueuePreservesSnapshot() throws {
            let suite = persistence.defaults
            usePersistence()
            resetPlayer(player)

            PlaybackStateStore.save(PlaybackStateSnapshot(
                trackIDs: [1, 2, 3], currentIndex: 1, elapsed: 30,
                isPlaying: false, savedAt: Date()), defaults: suite)

            player.togglePlayPause()

            let snap = PlaybackStateStore.load(defaults: suite)
            #expect(snap != nil, "snapshot must survive toggle on empty queue")
        }

        // MARK: - Test 5: Restore never writes regressed elapsed (Loss #3)

        @Test func testRestoreNeverWritesRegressedElapsed() async throws {
            let relPath = try createTestWAV(duration: 4.0)
            let (_, trackId) = try await insertTestTrack(relPath: relPath)

            let suite = persistence.defaults
            usePersistence()

            resetPlayer(player)

            let seed = PlaybackStateSnapshot(
                trackIDs: [trackId], currentIndex: 0, elapsed: 190,
                isPlaying: false, savedAt: Date())
            PlaybackStateStore.save(seed, defaults: suite)
            persistence.clearRecorded()

            player.resetRestoreForTesting()
            await player.restorePersistedQueue()

            let regressed = persistence.savedSnapshots.filter {
                $0.trackIDs == [trackId] && $0.elapsed < 190
            }

            #expect(regressed.isEmpty,
                "restore must not write regressed elapsed; found \(regressed.map(\.elapsed))")
        }

        // MARK: - Test 6: Restore with missing current track (Loss #5)

        @Test func testRestoreWithMissingCurrentTrackDoesNotApplyElapsedToWrongTrack() async throws {
            let relPath = try createTestWAV(duration: 4.0)
            let (_, realId) = try await insertTestTrack(relPath: relPath)

            let suite = persistence.defaults
            usePersistence()

            resetPlayer(player)

            PlaybackStateStore.save(PlaybackStateSnapshot(
                trackIDs: [999999, realId], currentIndex: 0, elapsed: 100,
                isPlaying: false, savedAt: Date()), defaults: suite)

            player.resetRestoreForTesting()
            await player.restorePersistedQueue()

            #expect(abs(player.currentTime - 0) <= 0.01,
                "elapsed must be 0 when saved current track is missing")
        }

        // MARK: - Test 7: Snapshot survives reinstall (Loss #4) — F8 proof

        @Test func testSnapshotSurvivesReinstall() async throws {
            // Both local tiers live in this test's in-memory store, so nothing
            // races the real App Group defaults or App Support file.
            let fakeCloud = FakePlaybackCloudBackend()
            let persistor = PlaybackPositionPersistor(cloudBackend: fakeCloud, stateStore: persistence)

            let snapshot = PlaybackStateSnapshot(
                trackIDs: [77], trackSyncIDs: ["cloud-sync-id-777"],
                currentIndex: 0, elapsed: 55.5, isPlaying: false, savedAt: Date())

            // Save through persistor: admission + composite store (file + defaults + cloud).
            persistor.save(candidate: snapshot, reason: .userSeek)

            // Simulate uninstall: wipe the local tiers.
            persistence.clear()

            // Cloud tier must retain the snapshot.
            let cloudSnapshot = await fakeCloud.load()
            #expect(cloudSnapshot != nil, "cloud tier must retain snapshot after local wipe")
            let cs = try #require(cloudSnapshot)
            #expect(abs(cs.elapsed - 55.5) <= 0.01,
                "cloud snapshot must match saved elapsed")
            #expect(cs.trackSyncIDs == ["cloud-sync-id-777"],
                "identity must be by syncID after reinstall")

            // loadBest from persistor returns cloud snapshot when local tiers are gone.
            let loaded = await persistor.loadBest()
            #expect(loaded != nil, "loadBest must return snapshot from cloud when local is wiped")
            #expect(loaded?.trackSyncIDs == ["cloud-sync-id-777"],
                "syncID identity must survive reinstall")
        }

        // MARK: - Test 8: Snapshot stores stable track identity (F1)

        @Test func testSnapshotStoresStableTrackIdentity() throws {
            let suite = persistence.defaults
            usePersistence()

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
            #expect(snapshot != nil, "snapshot must be saved")
            #expect(snapshot?.trackSyncIDs == ["sync-test-abc-123"],
                "trackSyncIDs must be populated from the queued track's syncID")
        }
    }
}

private enum TestError: Error {
    case noAudioFormat
    case noAudioBuffer
    case noID
}
