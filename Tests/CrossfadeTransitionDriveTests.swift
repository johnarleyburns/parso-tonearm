import AVFoundation
import Foundation
import Testing
@testable import TonearmCore

/// Drives the real `AudioPlayer` through whole plain crossfades, tick by tick, the way the
/// periodic time observer does. TestFlight 520 and 521 both aborted on an Objective-C exception
/// from an AVPlayer call made before the incoming track had loaded. XCTest reports such an
/// exception as a failure, so each case here fails loudly if the crossfade path can raise again.
extension SharedProductionSingletonTests {
    @MainActor
    /// Re-enabled (2026-11-19) — see `AudioPlayerJamendoLoadingTests`'s
    /// `@Suite` declaration and `Tests/SharedProductionSingletonTests.swift`.
    @Suite
    final class CrossfadeTransitionDriveTests {
        private let player = AudioPlayer.makeForTesting()
        private let outgoingSeconds = 6.0
        private var files: [URL] = []
        private var savedCrossfade = 0.0

        init() async throws {
            savedCrossfade = player.crossfadeSeconds
        }

        isolated deinit {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }

        // MARK: - Cases

        /// The TestFlight 521 crash: the fade window arrives while the incoming stream is still
        /// loading. The outgoing track must play out at full level, and the edge must end cleanly.
        @Test func testIncomingTrackThatNeverLoadsNeverRaisesAndNeverFades() async throws {
            let player = try prepareOutgoing(fadeSeconds: 2)
            player.queue = [row(1), row(2, remoteURL: "https://example.invalid/never-loads.mp3")]

            await sweep(player, through: 0...(outgoingSeconds + 0.5))

            #expect(!player.transitionStartedForCurrentEdge)
            #expect(player.player.volume == player.outputLevel, "the outgoing track keeps full level")
            #expect(player.crossfadePlayer == nil, "the edge is released at the end of the outgoing track")
            #expect(player.index == 0, "the queue advances through the normal end-of-track path")
        }

        /// The normal case once the stream has loaded: the incoming track starts, the outgoing one
        /// fades, and the crossfade hands over the queue.
        @Test func testIncomingTrackThatIsReadyBlendsAndHandsOver() async throws {
            let player = try prepareOutgoing(fadeSeconds: 2)
            let incoming = row(2, remoteURL: "https://example.invalid/preloaded.mp3")
            player.queue = [row(1), incoming]
            player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
            player.preloadedNextTrackId = 2

            let fadeStart = outgoingSeconds - 2
            #expect(player.prepareCrossfadePlayer(for: incoming, at: 1))
            let crossfade = try #require(player.crossfadePlayer)
            let loaded = await waitUntil { isLoaded(crossfade) }
            #expect(loaded, "local item should be ready in the fake")

            var sawBlend = false
            for position in stride(from: fadeStart, through: outgoingSeconds + 0.5, by: 0.1) {
                player.updateCrossfade(position: position)
                if player.index == 0, player.transitionStartedForCurrentEdge,
                   player.player.volume < player.outputLevel, (player.crossfadePlayer?.volume ?? 0) > 0 {
                    sawBlend = true
                }
                if player.index == 1 { break }
            }
            #expect(sawBlend, "both tracks should be audible together during the fade")
            #expect(player.index == 1, "the crossfade hands the queue to the incoming track")
        }

        /// Explicit Next must promote the prepared incoming item (same handoff as the natural
        /// boundary) instead of cancelling it and cold-rebuilding; it plays, with no failure banner.
        @Test func testManualNextPromotesPreparedCrossfadeItem() throws {
            let player = try prepareOutgoing(fadeSeconds: 3)
            let incoming = row(2, remoteURL: "https://example.invalid/manual-next.mp3")
            player.queue = [row(1), incoming]
            player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
            player.preloadedNextTrackId = 2
            #expect(player.prepareCrossfadePlayer(for: incoming, at: 1))
            let prepared = try #require(player.crossfadePlayer)
            let preparedItem = try #require(prepared.currentItem)

            player.next()

            #expect(player.index == 1)
            #expect(player.player === prepared, "the prepared player becomes the active player")
            #expect(player.player.currentItem === preparedItem)
            #expect(player.crossfadePlayer == nil)
            #expect(player.isPlaying, "play intent is preserved")
            #expect(player.networkSkipMessage == nil)
        }

        /// #417: when the prepared item cannot be promoted, the stale crossfade/loader state must be
        /// cleared synchronously so the fallback cold load starts clean.
        @Test func testFailedManualPromotionClearsStaleCrossfadeStateBeforeFallback() throws {
            let player = try prepareOutgoing(fadeSeconds: 3)
            player.queue = [row(1), row(2, remoteURL: "https://example.invalid/stale.mp3")]
            player.index = 1
            player.crossfadePlayer = FakePlayerEngine() // no item: not promotable
            player.crossfadeNextIndex = 1
            player.crossfadeNextTrackId = 2

            #expect(!player.promotePreparedCrossfadeForManualAdvance())

            #expect(player.crossfadePlayer == nil)
            #expect(player.crossfadeNextLoader == nil)
            #expect(player.crossfadeNextIndex == nil)
        }

        /// #417: an item advanced through `finishCrossfade` gets the same status/failure observer
        /// that `replaceItem` installs for ordinary loads.
        @Test func testFinishCrossfadeInstallsFailureDetection() throws {
            let player = try prepareOutgoing(fadeSeconds: 3)
            let incoming = row(2, remoteURL: "https://example.invalid/wired.mp3")
            player.queue = [row(1), incoming]
            player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
            player.preloadedNextTrackId = 2
            #expect(player.prepareCrossfadePlayer(for: incoming, at: 1))
            player.itemStatusCancellable = nil

            player.finishCrossfade(to: 1, row: incoming)

            #expect(player.itemStatusCancellable != nil)
        }

        /// Architecture-review finding (I6): every item installed as current must get the same
        /// stall watcher an ordinary load installs via `replaceItem` — a promoted crossfade item was
        /// the one path that skipped it, so a promoted-but-stuck item (never confirms real progress)
        /// had no detector at all and would sit silently stalled forever.
        @Test func testFinishCrossfadeArmsAStallWatchForThePromotedItem() throws {
            let player = try prepareOutgoing(fadeSeconds: 3)
            let incoming = row(2, remoteURL: "https://example.invalid/stall-watch.mp3")
            player.queue = [row(1), incoming]
            player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
            player.preloadedNextTrackId = 2
            #expect(player.prepareCrossfadePlayer(for: incoming, at: 1))
            player.stallWatchTask = nil

            player.finishCrossfade(to: 1, row: incoming)

            #expect(player.stallWatchTask != nil,
                            "a promoted item must get the same stall-timeout coverage an ordinary load installs")
        }

        /// Architecture-review finding: the outgoing item can reach its natural end before
        /// `updateCrossfade`'s own gain-based completion ever confirmed the incoming item was ready
        /// (e.g. a slow-opening stream). Promoting it anyway would strand playback on a paused item
        /// nothing watches for a stall; the natural boundary must fall back to the ordinary load path
        /// instead.
        @Test func testNaturalEndFallsBackToOrdinaryLoadWhenTheCrossfadeCandidateIsntReady() async throws {
            let outgoingItem = AVPlayerItem(url: try audioFile(seconds: 1))
            player.player.replaceCurrentItem(with: outgoingItem)
            player.observeEnd(of: outgoingItem)

            let nextRow = row(2, remoteURL: "https://example.invalid/ordinary-fallback.mp3")
            player.queue = [row(1), nextRow]
            player.index = 0
            // A crossfade candidate was prepared (the fade-lead window was reached) but never
            // became ready before the outgoing item ran out.
            let unready = FakePlayerEngine()
            unready.replaceCurrentItem(with: AVPlayerItem(url: URL(string: "https://example.invalid/never-ready.mp3")!))
            player.crossfadePlayer = unready
            player.crossfadeNextIndex = 1
            player.crossfadeNextTrackId = 2

            var builtURLs: [String] = []
            player.ordinaryBuildItemHook = { asset in
                builtURLs.append(asset.remoteURL ?? "nil")
                return (AVPlayerItem(asset: AVMutableComposition()), nil)
            }

            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: outgoingItem)

            let advanced = await waitUntil { player.index == 1 }
            #expect(advanced,
                    "the natural boundary must still advance the queue even when the crossfade candidate wasn't ready")
            #expect(player.crossfadePlayer == nil, "an unready crossfade candidate must be cancelled, not promoted")
            #expect(builtURLs == ["https://example.invalid/ordinary-fallback.mp3"],
                          "must fall back to the ordinary resolve/build path, not promote the unready item")
        }

        /// With Smart Transitions gone, this plain crossfade is the only track-to-track transition
        /// left — the shipped default must already be a real, audible blend, not `0` (a silent
        /// hard cut) that a setting nobody has found yet would need to raise first.
        @Test func testShippedDefaultCrossfadeSecondsProducesABlendWithoutAnyOverride() async throws {
            #expect(savedCrossfade == 3, "the shipped default must be a real, nonzero blend")
            let player = try prepareOutgoing(fadeSeconds: savedCrossfade)
            let incoming = row(2, remoteURL: "https://example.invalid/default-blend.mp3")
            player.queue = [row(1), incoming]
            player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
            player.preloadedNextTrackId = 2

            let fadeStart = outgoingSeconds - savedCrossfade
            #expect(player.prepareCrossfadePlayer(for: incoming, at: 1))
            let crossfade = try #require(player.crossfadePlayer)
            let loaded = await waitUntil { isLoaded(crossfade) }
            #expect(loaded, "local item should be ready in the fake")

            var sawBlend = false
            for position in stride(from: fadeStart, through: outgoingSeconds + 0.5, by: 0.1) {
                player.updateCrossfade(position: position)
                if player.index == 0, player.transitionStartedForCurrentEdge,
                   player.player.volume < player.outputLevel, (player.crossfadePlayer?.volume ?? 0) > 0 {
                    sawBlend = true
                }
                if player.index == 1 { break }
            }
            #expect(sawBlend, "both tracks should be audible together during the default blend")
            #expect(player.index == 1, "the default crossfade hands the queue to the incoming track")
        }

        /// The incoming track finishes loading partway through the fade window: the fade starts then.
        @Test func testIncomingTrackThatLoadsMidFadeStartsLate() async throws {
            let player = try prepareOutgoing(fadeSeconds: 4)
            let incoming = row(2, remoteURL: "https://example.invalid/late.mp3")
            player.queue = [row(1), incoming]
            player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
            player.preloadedNextTrackId = 2

            // First fade tick creates the incoming player before it has loaded: nothing may start.
            player.updateCrossfade(position: outgoingSeconds - 4)
            let crossfade = try #require(player.crossfadePlayer)
            if !isLoaded(crossfade) {
                #expect(!player.transitionStartedForCurrentEdge)
                #expect(player.player.volume == player.outputLevel)
            }
            let loaded = await waitUntil { isLoaded(crossfade) }
            #expect(loaded)
            player.updateCrossfade(position: outgoingSeconds - 2)
            #expect(player.transitionStartedForCurrentEdge, "the fade starts once the track is ready")
        }

        /// Real report: the volume swelled and dropped repeatedly for minutes in the middle of a
        /// track. A remote/streamed item's live `AVPlayerItem.duration` estimate can change as more
        /// of the file loads — simulated here by setting `player.duration` far below the track's
        /// real, library-known length. The fade window must be computed from that stable library
        /// duration, not the fluctuating live one, so a mid-track position is never mistaken for
        /// "near the end."
        @Test func testUnstableLiveDurationEstimateNeverDestabilizesTheFadeWindow() throws {
            let player = try prepareOutgoing(fadeSeconds: 2)
            let incoming = row(2, remoteURL: "https://example.invalid/next.mp3")
            player.queue = [row(1), incoming]
            // The real, library-known duration is outgoingSeconds (6s), fixed by `row(1)`'s
            // `durationSec`. A buggy live estimate of 3s would put the old code's fade window
            // starting at 1s (3 - 2 fadeSeconds) — well before the real fade window at 4s (6 - 2).
            player.duration = 3

            player.updateCrossfade(position: 2)
            #expect(player.player.volume == player.outputLevel,
                "position 2s must not be in the fade window — the real track is 6s long, not 3s")

            // Even once the live estimate "corrects" upward, it must still never win over the
            // library's own value.
            player.duration = 6
            player.updateCrossfade(position: 2)
            #expect(player.player.volume == player.outputLevel)
        }

        // MARK: - Helpers

        private func prepareOutgoing(fadeSeconds: Double) throws -> AudioPlayer {
            player.cancelCrossfade(resetVolume: true)
            player.sleepAtEndOfTrack = false
            player.repeatMode = .off
            player.crossfadeSeconds = fadeSeconds
            // Start from a known-paused state before driving the clock manually below.
            player.player.pause()
            player.isPlaying = false
            let item = AVPlayerItem(url: try audioFile(seconds: outgoingSeconds))
            player.player.automaticallyWaitsToMinimizeStalling = false
            player.player.replaceCurrentItem(with: item)
            #expect(player.player.isItemReady(item), "outgoing item should be ready in the fake")
            player.index = 0
            player.duration = outgoingSeconds
            return player
        }

        private func isLoaded(_ player: any PlayerEngine) -> Bool { player.isReady }

        private func sweep(_ player: AudioPlayer, through range: ClosedRange<Double>) async {
            for position in stride(from: range.lowerBound, through: range.upperBound, by: 0.1) {
                player.updateCrossfade(position: position)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }

        private func row(_ id: Int64, remoteURL: String? = nil) -> TrackRow {
            let source = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil, title: "Test",
                                addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                                licenseText: nil, memberCapHit: false)
            let track = Track(id: id, albumId: id, sourceId: 1, title: "Track \(id)", trackNo: nil, discNo: nil,
                              durationSec: outgoingSeconds, codec: "MP3", sampleRate: nil,
                              bitDepthOrBitrate: nil, sortKey: "\(id)")
            let asset = Asset(id: id, trackId: id, kind: .remote, bookmark: nil, relPath: nil,
                              remoteURL: remoteURL ?? "https://example.invalid/track-\(id).mp3",
                              altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
            return TrackRow(track: track, album: Album(id: id, sourceId: 1, title: "Album \(id)", artist: nil),
                            source: source, asset: asset)
        }

        /// A short silent audio file AVFoundation loads locally (no network in tests).
        private func audioFile(seconds: Double) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("crossfade-\(UUID().uuidString).caf")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(seconds * 44_100)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            try file.write(from: buffer)
            files.append(url)
            return url
        }
    }
}
