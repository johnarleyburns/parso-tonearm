import Foundation
import Testing
@testable import TonearmCore

/// Keep Playing (main-library queue continuation under Build a Mix's BPM/key/
/// energy rules via `KeepPlayingMixProviding`). Two layers:
///
/// - `KeepPlayingPicker` is pure (no player, no database) and is exercised
///   directly — this is where the dedup/no-immediate-repeat/gating
///   guarantees are actually proven, deterministically.
/// - The `AudioPlayer` integration tests below drive a freshly-constructed
///   player with a fake provider to prove the fallback path is honest (never
///   a silent no-op) and that turning Keep Playing off undoes its unplayed
///   tail. They still read real ids from `LibraryStore.shared` where needed:
///   `AudioPlayer`'s own Keep Playing fallback/continuation logic
///   (`AudioPlayer+KeepPlaying.swift`) resolves tracks through the real
///   shared `LibraryStore` internally, not through anything these tests
///   could inject, so hydration only ever succeeds against ids that are
///   really there. They either check ids fetched live from that store, or
///   assert on the fallback/flag surface alone, rather than asserting on
///   fixture ids the real on-disk store doesn't know about.
extension SharedProductionSingletonTests {
    @MainActor
    @Suite final class KeepPlayingTests {
        private let player = AudioPlayer.makeForTesting()

        private let src = Source(id: 1, kind: .iaItem, iaIdentifier: "x",
                                  originalURL: nil, title: "Test Source",
                                  addedAt: Date(), lastResolvedAt: nil,
                                  followUpdates: false, licenseText: nil, memberCapHit: false)
        private lazy var album = Album(id: 1, sourceId: 1, title: "Album", artist: "Artist")

        private func makeTrack(_ i: Int) -> TrackRow {
            let t = Track(id: Int64(i), albumId: 1, sourceId: 1,
                          title: "Track \(i)", trackNo: i, discNo: nil,
                          durationSec: 120, codec: "MP3", sampleRate: nil,
                          bitDepthOrBitrate: nil, sortKey: "\(i)")
            let a = Asset(id: Int64(i), trackId: Int64(i), kind: .remote,
                          bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/track\(i).mp3",
                          altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
            return TrackRow(track: t, album: album, source: src, asset: a)
        }

        init() throws {
            player.persistor = PlaybackPositionPersistor(
                stateStore: InMemoryPlaybackStatePersistence())
            Self.resetPlayerForTest(player)
        }

        private static func resetPlayerForTest(_ player: AudioPlayer) {
            player.keepPlayingEnabled = false
            player.keepPlayingMixProvider = nil
            player.keepPlayingExtensionTask?.cancel()
            player.resetRestoreForTesting()
            if !player.queue.isEmpty {
                player.removeFromQueue(atOffsets: IndexSet(0..<player.queue.count))
            }
            player.keepPlayingFallbackOrder = { $0 }
            player.repeatMode = .off
            player.shuffle = false
            player.keepPlayingEnabled = true
        }

        // MARK: - KeepPlayingPicker (pure) — dedup / no-immediate-repeat

        /// Reproduces the exact failure mode the spec calls out: a provider that
        /// (incorrectly, or just redundantly) returns the just-played track and a
        /// duplicate of another pick must never see those survive the filter.
        @Test func testDedupedCandidatesDropsExcludedAndDuplicateIDs() {
            // History + live queue contain 1, 2, 3 (3 is the just-played track);
            // the provider echoes 3 back, plus a duplicate of 10.
            let result = KeepPlayingPicker.dedupedCandidates([3, 10, 10, 11], excluding: [1, 2, 3])
            #expect(result == [10, 11])
        }

        @Test func testDedupedCandidatesPreservesOrder() {
            let result = KeepPlayingPicker.dedupedCandidates([30, 10, 20], excluding: [])
            #expect(result == [30, 10, 20], "best-match-first order must survive filtering")
        }

        @Test func testDedupedCandidatesWithNothingLeftIsEmptyNotCrashing() {
            #expect(KeepPlayingPicker.dedupedCandidates([1, 2], excluding: [1, 2]) == [])
        }

        // MARK: - KeepPlayingPicker (pure) — gating

        @Test func testShouldAttemptExtensionFiresOnLastOrSecondToLastTrack() {
            #expect(KeepPlayingPicker.shouldAttemptExtension(
                enabled: true, isAmbient: false, repeatMode: .off,
                queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: false))
            #expect(KeepPlayingPicker.shouldAttemptExtension(
                enabled: true, isAmbient: false, repeatMode: .off,
                queueCount: 3, index: 1, lastAttemptedIndex: nil, extensionInFlight: false))
        }

        @Test func testKeepPlayingEndCanRetryAfterAnEmptyExtension() {
            #expect(KeepPlayingPicker.shouldAttemptExtension(
                enabled: true, isAmbient: false, repeatMode: .off,
                queueCount: 1, index: 0, lastAttemptedIndex: nil, extensionInFlight: false))
        }

        @Test func testShouldAttemptExtensionDoesNotFireInTheMiddleOfALongQueue() {
            #expect(!KeepPlayingPicker.shouldAttemptExtension(
                enabled: true, isAmbient: false, repeatMode: .off,
                queueCount: 10, index: 3, lastAttemptedIndex: nil, extensionInFlight: false))
        }

        @Test func testShouldAttemptExtensionRespectsTheEnabledToggle() {
            #expect(!KeepPlayingPicker.shouldAttemptExtension(
                enabled: false, isAmbient: false, repeatMode: .off,
                queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: false))
        }

        @Test func testShouldAttemptExtensionNeverFiresForAmbientOrLoopingRepeatModes() {
            #expect(!KeepPlayingPicker.shouldAttemptExtension(
                enabled: true, isAmbient: true, repeatMode: .off,
                queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: false))
            #expect(!KeepPlayingPicker.shouldAttemptExtension(
                enabled: true, isAmbient: false, repeatMode: .all,
                queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: false),
                "repeat-all already loops the queue forever")
            #expect(!KeepPlayingPicker.shouldAttemptExtension(
                enabled: true, isAmbient: false, repeatMode: .one,
                queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: false),
                "repeat-one never advances past the current track")
        }

        @Test func testShouldAttemptExtensionDoesNotDoubleFireForTheSamePosition() {
            #expect(!KeepPlayingPicker.shouldAttemptExtension(
                enabled: true, isAmbient: false, repeatMode: .off,
                queueCount: 3, index: 2, lastAttemptedIndex: 2, extensionInFlight: false))
            #expect(!KeepPlayingPicker.shouldAttemptExtension(
                enabled: true, isAmbient: false, repeatMode: .off,
                queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: true))
        }

        // MARK: - Fakes for the AudioPlayer integration tests

        /// Always answers a fixed result regardless of what it's asked to
        /// exclude — the exclusion/dedup guarantee is `AudioPlayer`'s job (see
        /// `KeepPlayingPicker` above), this fake exists to drive the fallback and
        /// state-surfacing paths.
        @MainActor
        private final class FixedProvider: KeepPlayingMixProviding {
            let result: KeepPlayingMixResult
            private(set) var lastAnchor: Int64?
            private(set) var lastExcluding: Set<Int64> = []
            private(set) var callCount = 0

            init(_ result: KeepPlayingMixResult) { self.result = result }

            func mixContinuation(
                after trackID: Int64, excluding: Set<Int64>, limit: Int
            ) async -> KeepPlayingMixResult {
                callCount += 1
                lastAnchor = trackID
                lastExcluding = excluding
                return result
            }
        }

        @MainActor
        private final class FixedContinuation: QueueContinuationSource {
            let rows: [TrackRow]
            private(set) var callCount = 0

            init(rows: [TrackRow]) { self.rows = rows }

            func nextTracks(excluding: Set<Int64>, limit: Int) async -> [TrackRow] {
                callCount += 1
                return Array(rows.filter { row in
                    guard let id = row.track.id else { return false }
                    return !excluding.contains(id)
                }.prefix(limit))
            }
        }

        /// `play(tracks:startAt:)` itself can trigger `maybeExtendKeepPlayingQueue`
        /// synchronously (fire-and-forget `Task`) when it lands on the last/
        /// second-to-last track — disabling Keep Playing for the call keeps that
        /// automatic attempt from racing the test's own explicit
        /// `extendKeepPlayingQueueForTesting()` call.
        private func playWithoutAutoExtending(_ player: AudioPlayer, tracks: [TrackRow], startAt: Int) {
            player.keepPlayingEnabled = false
            player.play(tracks: tracks, startAt: startAt)
            player.keepPlayingEnabled = true
        }

        // MARK: - The exclusion set handed to the provider

        /// The exclusion set handed to the provider must cover both the whole
        /// play history and every track still sitting in the live queue — not
        /// just the single most-recently-played track — and the history must
        /// list the most-recently-played track first.
        @Test func testExclusionSetCoversHistoryAndCurrentQueue() async {
            let tracks = (1...3).map { makeTrack($0) }
            playWithoutAutoExtending(player, tracks: tracks, startAt: 2)

            let provider = FixedProvider(.init(trackIDs: [100]))
            player.keepPlayingMixProvider = provider

            await player.extendKeepPlayingQueueForTesting()

            #expect(provider.lastExcluding.isSuperset(of: [1, 2, 3]))
            #expect(provider.lastAnchor == 3, "the mix continues from the last queued track")
        }

        // MARK: - Fallback when no BPM/key/energy candidate is available

        /// A model that's available but genuinely has no candidates is a
        /// different, distinct reason from "still downloading" — both are
        /// fallbacks, but the UI can only tell the user the truth if these stay
        /// separate.
        @Test func testEmptyMixFallsBackAndRecordsTheReason() async {
            let tracks = (1...3).map { makeTrack($0) }
            playWithoutAutoExtending(player, tracks: tracks, startAt: 2)
            player.keepPlayingMixProvider = FixedProvider(.empty)

            await player.extendKeepPlayingQueueForTesting()

            #expect(player.keepPlayingLastExtensionWasFallback)
            #expect(player.keepPlayingFallbackReason == .noCompatibleTracks)
        }

        /// No provider wired at all (the state under `swift test`, and on first
        /// launch before the app finishes assembling Discovery) must behave
        /// exactly like an explicit `.unavailable` answer — never crash, never a
        /// silent no-op.
        @Test func testNoMixProviderWiredFallsBackWithoutCrashing() async {
            let tracks = (1...3).map { makeTrack($0) }
            playWithoutAutoExtending(player, tracks: tracks, startAt: 2)
            player.keepPlayingMixProvider = nil

            await player.extendKeepPlayingQueueForTesting()

            #expect(player.keepPlayingLastExtensionWasFallback)
            #expect(player.keepPlayingFallbackReason == .noCompatibleTracks)
        }

        /// Remote browse queues have no persisted source id to use as a fallback.
        /// Their explicit continuation must be preferred so a one-track Jamendo
        /// play-now action becomes a real queue instead of ending in dead air.
        @Test func testQueueContinuationAppendsRemoteTracksWithoutFallback() async {
            let continuation = FixedContinuation(rows: [makeTrack(2), makeTrack(3)])

            player.keepPlayingEnabled = false
            player.play(tracks: [makeTrack(1)], startAt: 0,
                        source: .continuation(continuation))
            player.keepPlayingEnabled = true
            await player.extendKeepPlayingQueueForTesting()

            #expect(player.queue.map(\.id) == [1, 2, 3])
            #expect(continuation.callCount == 1)
            #expect(!player.keepPlayingLastExtensionWasFallback)
            #expect(player.keepPlayingFallbackReason == nil)
        }

        /// An empty mix result (no analysed candidate at all) must also fall
        /// back rather than silently leaving the queue to run dry.
        @Test func testEmptyMixResultFallsBack() async {
            let tracks = (1...3).map { makeTrack($0) }
            playWithoutAutoExtending(player, tracks: tracks, startAt: 2)
            player.keepPlayingMixProvider = FixedProvider(.empty)

            await player.extendKeepPlayingQueueForTesting()

            #expect(player.keepPlayingLastExtensionWasFallback)
        }

        // MARK: - A real mix pick appends without a fallback marker

        /// Uses ids actually present in the shared `LibraryStore` (so hydration
        /// via `LibraryStore.shared.trackRow(id:)` succeeds for real, rather than
        /// asserting against fixture ids the real on-disk store doesn't know
        /// about) to prove the non-fallback path appends exactly what the
        /// provider returned and marks it as Keep Playing's own.
        @Test func testReadyMixPicksAppendWithoutFallbackMarker() async throws {
            // Exclude the fixture ids this suite queues (1...3): another parallel
            // suite's temporary shared-library rows must never be mistaken for
            // new continuation candidates, or the extension correctly dedupes
            // them and these assertions see a fallback instead.
            let realIDs = ((try? await LibraryStore.shared.allTrackRows())?.compactMap { $0.track.id } ?? [])
                .filter { !(1...3).contains($0) }
            if realIDs.count < 2 { try Test.cancel("Needs at least two tracks in the shared library to hydrate against") }
            let picks = Array(realIDs.prefix(2))

            let tracks = (1...3).map { makeTrack($0) }
            playWithoutAutoExtending(player, tracks: tracks, startAt: 2)
            player.keepPlayingMixProvider = FixedProvider(.init(trackIDs: picks))

            await player.extendKeepPlayingQueueForTesting()

            #expect(!player.keepPlayingLastExtensionWasFallback)
            #expect(player.keepPlayingFallbackReason == nil)
            #expect(Array(player.queue.dropFirst(3).map(\.id)) == picks)
            #expect(Set(player.keepPlayingAutoAddedTrackIDs) == Set(picks))
        }

        // MARK: - Turning Keep Playing off removes the not-yet-played auto-added tail

        @Test func testTurningOffKeepPlayingRemovesUnplayedAutoAddedTracksOnly() async throws {
            // Exclude the fixture ids this suite queues (1...3): another parallel
            // suite's temporary shared-library rows must never be mistaken for
            // new continuation candidates, or the extension correctly dedupes
            // them and these assertions see a fallback instead.
            let realIDs = ((try? await LibraryStore.shared.allTrackRows())?.compactMap { $0.track.id } ?? [])
                .filter { !(1...3).contains($0) }
            if realIDs.count < 2 { try Test.cancel("Needs at least two tracks in the shared library to hydrate against") }
            let picks = Array(realIDs.prefix(2))

            let tracks = (1...3).map { makeTrack($0) }
            // index 0: tracks 2 and 3 are manually-queued "unplayed" tracks that
            // must survive turning Keep Playing off.
            player.play(tracks: tracks, startAt: 0)

            player.keepPlayingMixProvider = FixedProvider(.init(trackIDs: picks))
            await player.extendKeepPlayingQueueForTesting()
            #expect(player.queue.map(\.id) == [1, 2, 3] + picks)

            player.keepPlayingEnabled = false

            #expect(player.queue.map(\.id) == [1, 2, 3], "manually-queued tracks 2/3 must survive")
            #expect(player.keepPlayingAutoAddedTrackIDs.isEmpty)
        }

        /// `removeUnplayedKeepPlayingTracks` (the explicit "Clear auto-added
        /// tracks" affordance) must never touch a track before the current
        /// index, even if that track happened to be auto-added by an earlier
        /// extension — it already played, so it's history, not a pending
        /// auto-add to undo.
        @Test func testClearAutoAddedNeverRemovesAlreadyPlayedTracks() async throws {
            // Exclude the fixture ids this suite queues (1...3): another parallel
            // suite's temporary shared-library rows must never be mistaken for
            // new continuation candidates, or the extension correctly dedupes
            // them and these assertions see a fallback instead.
            let realIDs = ((try? await LibraryStore.shared.allTrackRows())?.compactMap { $0.track.id } ?? [])
                .filter { !(1...3).contains($0) }
            if realIDs.count < 2 { try Test.cancel("Needs at least two tracks in the shared library to hydrate against") }
            let picks = Array(realIDs.prefix(2))

            let tracks = (1...2).map { makeTrack($0) }
            playWithoutAutoExtending(player, tracks: tracks, startAt: 1)  // index 1 (last manual track)

            player.keepPlayingMixProvider = FixedProvider(.init(trackIDs: picks))
            await player.extendKeepPlayingQueueForTesting()
            #expect(player.queue.map(\.id) == [1, 2] + picks)

            player.skipToIndex(2)  // "play" the first auto-added track
            player.removeUnplayedKeepPlayingTracks()

            #expect(player.queue.map(\.id) == [1, 2, picks[0]],
                           "the played auto-add stays; the unplayed one is removed")
        }

        // MARK: - Extension only fires near the end of the queue (integration)

        @Test func testExtensionDoesNotFireInTheMiddleOfALongQueue() async {
            let tracks = (1...10).map { makeTrack($0) }
            player.play(tracks: tracks, startAt: 0)

            let provider = FixedProvider(.init(trackIDs: [100]))
            player.keepPlayingMixProvider = provider
            player.skipToIndex(3)  // 7 tracks still left — nowhere near the end

            // `skipToIndex` -> `loadCurrent` already ran `maybeExtendKeepPlayingQueue`
            // synchronously; give any (wrongly) spawned Task a beat to land.
            try? await Task.sleep(nanoseconds: 50_000_000)

            #expect(provider.callCount == 0)
        }

        @Test func testRepeatAllNeverExtends() async {
            let tracks = (1...3).map { makeTrack($0) }
            player.repeatMode = .all
            player.play(tracks: tracks, startAt: 2)  // last track, but repeat-all loops forever

            let provider = FixedProvider(.init(trackIDs: [100]))
            player.keepPlayingMixProvider = provider
            // `play(tracks:startAt:)` already ran `loadCurrent` -> `maybeExtendKeepPlayingQueue`
            // once; re-run the gate explicitly to be sure repeat-all keeps blocking it.
            player.maybeExtendKeepPlayingQueue()
            try? await Task.sleep(nanoseconds: 50_000_000)

            #expect(provider.callCount == 0)
        }

        // MARK: - Dead air: next() at end of queue must resume once a
        // still-in-flight extension lands

        @Test func testNextAtEndOfQueueResumesOnceInFlightExtensionLands() async throws {
            // Exclude the fixture ids this suite queues (1...3): another parallel
            // suite's temporary shared-library rows must never be mistaken for
            // new continuation candidates, or the extension correctly dedupes
            // them and these assertions see a fallback instead.
            let realIDs = ((try? await LibraryStore.shared.allTrackRows())?.compactMap { $0.track.id } ?? [])
                .filter { !(1...3).contains($0) }
            if realIDs.isEmpty { try Test.cancel("Needs at least one track in the shared library to hydrate against") }
            let pick = realIDs[0]

            let tracks = [makeTrack(1)]
            playWithoutAutoExtending(player, tracks: tracks, startAt: 0)  // the one and only track, already "playing"

            // Simulate `maybeExtendKeepPlayingQueue` having already kicked off a
            // real extension for this position, so it can still be running when
            // the last track ends.
            player.keepPlayingExtensionInFlight = true

            player.next()  // the track just finished; queue is exhausted

            #expect(!player.isPlaying, "nothing to play yet — this is the real dead-air moment")
            #expect(player.keepPlayingBoundaryState ==
                           .waiting(queueGeneration: player.keepPlayingBoundaryGeneration, terminalIndex: 0),
                          "next() must remember it stopped only because an extension was still in flight")

            player.keepPlayingMixProvider = FixedProvider(.init(trackIDs: [pick]))
            await player.extendKeepPlayingQueueForTesting()

            #expect(player.queue.map(\.id) == [1, pick])
            #expect(player.isPlaying, "the extension landed real tracks — playback must actually resume, not sit queued-but-silent")
            #expect(player.index == 1)
            #expect(player.keepPlayingBoundaryState == .idle)
        }

        /// The same race, but the extension comes back with nothing playable
        /// (a real "no matches" or empty fallback pool) — must NOT force a
        /// resume into an unchanged, still-exhausted queue.
        @Test func testNextAtEndOfQueueStaysStoppedWhenExtensionFindsNothing() async {
            // No shared-library fallback: another parallel suite's tracks must
            // never turn this deliberate "nothing playable" case into a resume.
            player.keepPlayingLibrary = .empty
            let tracks = [makeTrack(1)]
            playWithoutAutoExtending(player, tracks: tracks, startAt: 0)

            player.keepPlayingExtensionInFlight = true
            player.next()
            #expect(player.keepPlayingBoundaryState ==
                           .waiting(queueGeneration: player.keepPlayingBoundaryGeneration, terminalIndex: 0))

            player.keepPlayingMixProvider = FixedProvider(.empty)
            await player.extendKeepPlayingQueueForTesting()

            #expect(!player.isPlaying)
            #expect(player.keepPlayingBoundaryState ==
                           .exhausted(queueGeneration: player.keepPlayingBoundaryGeneration, terminalIndex: 0))
        }

        /// A playlist is a starting scope, not a hard stop for Keep Playing. Once
        /// every playlist item has been consumed, the fallback must be able to
        /// choose an eligible track from the rest of the library instead of
        /// returning the already-exhausted playlist and producing dead air.
        @Test func testPlaylistKeepPlayingContinuesFromTheLibraryAfterPlaylistEnds() async throws {
            let store = LibraryStore.shared
            let source = try await store.insertSource(Source(
                id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                title: "Keep Playing Playlist Fixture \(UUID().uuidString)",
                addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                licenseText: nil, memberCapHit: false))
            let sourceID = try #require(source.id)
            let first = try await store.insertTrack(Track(
                id: nil, albumId: nil, sourceId: sourceID, title: "Playlist Start",
                trackNo: 1, discNo: nil, durationSec: 120, codec: "MP3",
                sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "fixture-1"))
            let continuation = try await store.insertTrack(Track(
                id: nil, albumId: nil, sourceId: sourceID, title: "Library Continuation",
                trackNo: 2, discNo: nil, durationSec: 120, codec: "MP3",
                sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "fixture-2"))
            let firstID = try #require(first.id)
            let continuationID = try #require(continuation.id)
            let playlist = try await store.createManualPlaylist(
                title: "Keep Playing Fixture \(UUID().uuidString)", trackIds: [firstID])
            let playlistRows = try await store.playlistItems(playlistId: try #require(playlist.id))

            playWithoutAutoExtending(player, tracks: playlistRows, startAt: 0)
            player.queueSource = .playlist(playlist)
            player.keepPlayingMixProvider = nil
            await player.extendKeepPlayingQueueForTesting()

            #expect(player.queue.contains { $0.id == continuationID },
                          "Keep Playing must continue beyond an exhausted playlist")

            try? await store.deletePlaylist(id: try #require(playlist.id))
            try? await store.deleteSource(id: sourceID)
        }
    }
}

