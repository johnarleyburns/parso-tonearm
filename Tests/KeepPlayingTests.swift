import XCTest
@testable import TonearmCore

/// Keep Playing (main-library queue continuation, reusing the C01–C09 CLAP
/// vector index via `KeepPlayingSimilarityProviding`). Two layers:
///
/// - `KeepPlayingPicker` is pure (no player, no database) and is exercised
///   directly — this is where the dedup/no-immediate-repeat/gating
///   guarantees are actually proven, deterministically.
/// - The `AudioPlayer` integration tests below drive the real singleton with
///   a fake provider to prove the fallback path is honest (never a silent
///   no-op) and that turning Keep Playing off undoes its unplayed tail. They
///   avoid asserting on which *rows* got appended when that would require
///   `LibraryStore.shared` (the real, on-disk library, not a fixture) to
///   contain specific track ids — instead they either check ids fetched live
///   from that store, or assert on the fallback/flag surface alone.
@MainActor
final class KeepPlayingTests: XCTestCase {

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

    nonisolated override func tearDown() {
        MainActor.assumeIsolated {
            let player = AudioPlayer.shared
            player.keepPlayingProvider = nil
            player.keepPlayingEnabled = true
            player.keepPlayingBatchSize = 15
            player.repeatMode = .off
            player.shuffle = false
        }
        super.tearDown()
    }

    // MARK: - KeepPlayingPicker (pure) — dedup / no-immediate-repeat

    /// Reproduces the exact failure mode the spec calls out: a provider that
    /// (incorrectly, or just redundantly) returns the just-played track and a
    /// duplicate of another pick must never see those survive the filter.
    func testDedupedCandidatesDropsExcludedAndDuplicateIDs() {
        // History + live queue contain 1, 2, 3 (3 is the just-played track);
        // the provider echoes 3 back, plus a duplicate of 10.
        let result = KeepPlayingPicker.dedupedCandidates([3, 10, 10, 11], excluding: [1, 2, 3])
        XCTAssertEqual(result, [10, 11])
    }

    func testDedupedCandidatesPreservesOrder() {
        let result = KeepPlayingPicker.dedupedCandidates([30, 10, 20], excluding: [])
        XCTAssertEqual(result, [30, 10, 20], "best-match-first order must survive filtering")
    }

    func testDedupedCandidatesWithNothingLeftIsEmptyNotCrashing() {
        XCTAssertEqual(KeepPlayingPicker.dedupedCandidates([1, 2], excluding: [1, 2]), [])
    }

    // MARK: - KeepPlayingPicker (pure) — gating

    func testShouldAttemptExtensionFiresOnLastOrSecondToLastTrack() {
        XCTAssertTrue(KeepPlayingPicker.shouldAttemptExtension(
            enabled: true, isAmbient: false, repeatMode: .off,
            queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: false))
        XCTAssertTrue(KeepPlayingPicker.shouldAttemptExtension(
            enabled: true, isAmbient: false, repeatMode: .off,
            queueCount: 3, index: 1, lastAttemptedIndex: nil, extensionInFlight: false))
    }

    func testShouldAttemptExtensionDoesNotFireInTheMiddleOfALongQueue() {
        XCTAssertFalse(KeepPlayingPicker.shouldAttemptExtension(
            enabled: true, isAmbient: false, repeatMode: .off,
            queueCount: 10, index: 3, lastAttemptedIndex: nil, extensionInFlight: false))
    }

    func testShouldAttemptExtensionRespectsTheEnabledToggle() {
        XCTAssertFalse(KeepPlayingPicker.shouldAttemptExtension(
            enabled: false, isAmbient: false, repeatMode: .off,
            queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: false))
    }

    func testShouldAttemptExtensionNeverFiresForAmbientOrLoopingRepeatModes() {
        XCTAssertFalse(KeepPlayingPicker.shouldAttemptExtension(
            enabled: true, isAmbient: true, repeatMode: .off,
            queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: false))
        XCTAssertFalse(KeepPlayingPicker.shouldAttemptExtension(
            enabled: true, isAmbient: false, repeatMode: .all,
            queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: false),
            "repeat-all already loops the queue forever")
        XCTAssertFalse(KeepPlayingPicker.shouldAttemptExtension(
            enabled: true, isAmbient: false, repeatMode: .one,
            queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: false),
            "repeat-one never advances past the current track")
    }

    func testShouldAttemptExtensionDoesNotDoubleFireForTheSamePosition() {
        XCTAssertFalse(KeepPlayingPicker.shouldAttemptExtension(
            enabled: true, isAmbient: false, repeatMode: .off,
            queueCount: 3, index: 2, lastAttemptedIndex: 2, extensionInFlight: false))
        XCTAssertFalse(KeepPlayingPicker.shouldAttemptExtension(
            enabled: true, isAmbient: false, repeatMode: .off,
            queueCount: 3, index: 2, lastAttemptedIndex: nil, extensionInFlight: true))
    }

    // MARK: - Fakes for the AudioPlayer integration tests

    /// Always answers a fixed result regardless of what it's asked to
    /// exclude — the exclusion/dedup guarantee is `AudioPlayer`'s job (see
    /// `KeepPlayingPicker` above), this fake exists to drive the fallback and
    /// state-surfacing paths.
    @MainActor
    private final class FixedProvider: KeepPlayingSimilarityProviding {
        let result: KeepPlayingLookup
        private(set) var lastRecentlyPlayed: [Int64] = []
        private(set) var lastExcluding: Set<Int64> = []
        private(set) var callCount = 0

        init(_ result: KeepPlayingLookup) { self.result = result }

        func continuationTrackIDs(
            after recentlyPlayed: [Int64], excluding: Set<Int64>, limit: Int
        ) async -> KeepPlayingLookup {
            callCount += 1
            lastRecentlyPlayed = recentlyPlayed
            lastExcluding = excluding
            return result
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
    func testExclusionSetCoversHistoryAndCurrentQueue() async {
        let player = AudioPlayer.shared
        let tracks = (1...3).map { makeTrack($0) }
        playWithoutAutoExtending(player, tracks: tracks, startAt: 2)

        let provider = FixedProvider(.ready([100]))
        player.keepPlayingProvider = provider

        await player.extendKeepPlayingQueueForTesting()

        XCTAssertTrue(provider.lastExcluding.isSuperset(of: [1, 2, 3]))
        XCTAssertEqual(provider.lastRecentlyPlayed.first, 3, "most-recently-played track leads the list")
    }

    // MARK: - Fallback when the model/index isn't available

    /// `.waitingForModel` must never be treated as "nothing to do" — Keep
    /// Playing falls back to a shuffle-continue and records *why*, per
    /// CLAUDE.md "no silent/magic background work": a substituted behavior is
    /// always visible, never silent.
    func testWaitingForModelFallsBackAndRecordsTheReason() async {
        let player = AudioPlayer.shared
        let tracks = (1...3).map { makeTrack($0) }
        playWithoutAutoExtending(player, tracks: tracks, startAt: 2)
        player.keepPlayingProvider = FixedProvider(.waitingForModel)

        await player.extendKeepPlayingQueueForTesting()

        XCTAssertTrue(player.keepPlayingLastExtensionWasFallback)
        XCTAssertEqual(player.keepPlayingFallbackReason, .waitingForModel)
    }

    /// A model that's available but genuinely has no candidates is a
    /// different, distinct reason from "still downloading" — both are
    /// fallbacks, but the UI can only tell the user the truth if these stay
    /// separate.
    func testUnavailableFallsBackWithADistinctReasonFromWaitingForModel() async {
        let player = AudioPlayer.shared
        let tracks = (1...3).map { makeTrack($0) }
        playWithoutAutoExtending(player, tracks: tracks, startAt: 2)
        player.keepPlayingProvider = FixedProvider(.unavailable)

        await player.extendKeepPlayingQueueForTesting()

        XCTAssertTrue(player.keepPlayingLastExtensionWasFallback)
        XCTAssertEqual(player.keepPlayingFallbackReason, .unavailable)
    }

    /// No provider wired at all (the state under `swift test`, and on first
    /// launch before the app finishes assembling Discovery) must behave
    /// exactly like an explicit `.unavailable` answer — never crash, never a
    /// silent no-op.
    func testNoProviderWiredFallsBackWithoutCrashing() async {
        let player = AudioPlayer.shared
        let tracks = (1...3).map { makeTrack($0) }
        playWithoutAutoExtending(player, tracks: tracks, startAt: 2)
        player.keepPlayingProvider = nil

        await player.extendKeepPlayingQueueForTesting()

        XCTAssertTrue(player.keepPlayingLastExtensionWasFallback)
        XCTAssertEqual(player.keepPlayingFallbackReason, .unavailable)
    }

    /// An empty `.ready([])` result (provider found literally nothing) must
    /// also fall back rather than silently leaving the queue to run dry.
    func testEmptyReadyResultFallsBack() async {
        let player = AudioPlayer.shared
        let tracks = (1...3).map { makeTrack($0) }
        playWithoutAutoExtending(player, tracks: tracks, startAt: 2)
        player.keepPlayingProvider = FixedProvider(.ready([]))

        await player.extendKeepPlayingQueueForTesting()

        XCTAssertTrue(player.keepPlayingLastExtensionWasFallback)
    }

    // MARK: - A real similarity pick appends without a fallback marker

    /// Uses ids actually present in the shared `LibraryStore` (so hydration
    /// via `LibraryStore.shared.trackRow(id:)` succeeds for real, rather than
    /// asserting against fixture ids the real on-disk store doesn't know
    /// about) to prove the non-fallback path appends exactly what the
    /// provider returned and marks it as Keep Playing's own.
    func testReadySimilarityPicksAppendWithoutFallbackMarker() async throws {
        let realIDs = (try? await LibraryStore.shared.allTrackRows())?.compactMap { $0.track.id } ?? []
        try XCTSkipIf(realIDs.count < 2, "Needs at least two tracks in the shared library to hydrate against")
        let picks = Array(realIDs.prefix(2))

        let player = AudioPlayer.shared
        let tracks = (1...3).map { makeTrack($0) }
        playWithoutAutoExtending(player, tracks: tracks, startAt: 2)
        player.keepPlayingProvider = FixedProvider(.ready(picks))

        await player.extendKeepPlayingQueueForTesting()

        XCTAssertFalse(player.keepPlayingLastExtensionWasFallback)
        XCTAssertNil(player.keepPlayingFallbackReason)
        XCTAssertEqual(Array(player.queue.dropFirst(3).map(\.id)), picks)
        XCTAssertEqual(Set(player.keepPlayingAutoAddedTrackIDs), Set(picks))
    }

    // MARK: - Turning Keep Playing off removes the not-yet-played auto-added tail

    func testTurningOffKeepPlayingRemovesUnplayedAutoAddedTracksOnly() async throws {
        let realIDs = (try? await LibraryStore.shared.allTrackRows())?.compactMap { $0.track.id } ?? []
        try XCTSkipIf(realIDs.count < 2, "Needs at least two tracks in the shared library to hydrate against")
        let picks = Array(realIDs.prefix(2))

        let player = AudioPlayer.shared
        let tracks = (1...3).map { makeTrack($0) }
        // index 0: tracks 2 and 3 are manually-queued "unplayed" tracks that
        // must survive turning Keep Playing off.
        player.play(tracks: tracks, startAt: 0)

        player.keepPlayingProvider = FixedProvider(.ready(picks))
        await player.extendKeepPlayingQueueForTesting()
        XCTAssertEqual(player.queue.map(\.id), [1, 2, 3] + picks)

        player.keepPlayingEnabled = false

        XCTAssertEqual(player.queue.map(\.id), [1, 2, 3], "manually-queued tracks 2/3 must survive")
        XCTAssertTrue(player.keepPlayingAutoAddedTrackIDs.isEmpty)
    }

    /// `removeUnplayedKeepPlayingTracks` (the explicit "Clear auto-added
    /// tracks" affordance) must never touch a track before the current
    /// index, even if that track happened to be auto-added by an earlier
    /// extension — it already played, so it's history, not a pending
    /// auto-add to undo.
    func testClearAutoAddedNeverRemovesAlreadyPlayedTracks() async throws {
        let realIDs = (try? await LibraryStore.shared.allTrackRows())?.compactMap { $0.track.id } ?? []
        try XCTSkipIf(realIDs.count < 2, "Needs at least two tracks in the shared library to hydrate against")
        let picks = Array(realIDs.prefix(2))

        let player = AudioPlayer.shared
        let tracks = (1...2).map { makeTrack($0) }
        playWithoutAutoExtending(player, tracks: tracks, startAt: 1)  // index 1 (last manual track)

        player.keepPlayingProvider = FixedProvider(.ready(picks))
        await player.extendKeepPlayingQueueForTesting()
        XCTAssertEqual(player.queue.map(\.id), [1, 2] + picks)

        player.skipToIndex(2)  // "play" the first auto-added track
        player.removeUnplayedKeepPlayingTracks()

        XCTAssertEqual(player.queue.map(\.id), [1, 2, picks[0]],
                       "the played auto-add stays; the unplayed one is removed")
    }

    // MARK: - Extension only fires near the end of the queue (integration)

    func testExtensionDoesNotFireInTheMiddleOfALongQueue() async {
        let player = AudioPlayer.shared
        let tracks = (1...10).map { makeTrack($0) }
        player.play(tracks: tracks, startAt: 0)

        let provider = FixedProvider(.ready([100]))
        player.keepPlayingProvider = provider
        player.skipToIndex(3)  // 7 tracks still left — nowhere near the end

        // `skipToIndex` -> `loadCurrent` already ran `maybeExtendKeepPlayingQueue`
        // synchronously; give any (wrongly) spawned Task a beat to land.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(provider.callCount, 0)
    }

    func testRepeatAllNeverExtends() async {
        let player = AudioPlayer.shared
        let tracks = (1...3).map { makeTrack($0) }
        player.repeatMode = .all
        player.play(tracks: tracks, startAt: 2)  // last track, but repeat-all loops forever

        let provider = FixedProvider(.ready([100]))
        player.keepPlayingProvider = provider
        // `play(tracks:startAt:)` already ran `loadCurrent` -> `maybeExtendKeepPlayingQueue`
        // once; re-run the gate explicitly to be sure repeat-all keeps blocking it.
        player.maybeExtendKeepPlayingQueue()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(provider.callCount, 0)
    }
}
