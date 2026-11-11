import AVFoundation
import XCTest
@testable import TonearmCore

/// Drives the real `AudioPlayer` through whole plain crossfades, tick by tick, the way the
/// periodic time observer does. TestFlight 520 and 521 both aborted on an Objective-C exception
/// from an AVPlayer call made before the incoming track had loaded. XCTest reports such an
/// exception as a failure, so each case here fails loudly if the crossfade path can raise again.
@MainActor
final class CrossfadeTransitionDriveTests: XCTestCase {
    private let outgoingSeconds = 6.0
    private var files: [URL] = []
    private var savedCrossfade = 0.0

    override func setUp() async throws {
        try await super.setUp()
        savedCrossfade = AudioPlayer.shared.crossfadeSeconds
    }

    override func tearDown() async throws {
        let player = AudioPlayer.shared
        player.cancelCrossfade(resetVolume: true)
        player.player.replaceCurrentItem(with: nil)
        player.preloadedNextItem = nil
        player.preloadedNextTrackId = nil
        player.queue = []
        player.index = 0
        player.duration = 0
        player.crossfadeSeconds = savedCrossfade
        for file in files { try? FileManager.default.removeItem(at: file) }
        try await super.tearDown()
    }

    // MARK: - Cases

    /// The TestFlight 521 crash: the fade window arrives while the incoming stream is still
    /// loading. The outgoing track must play out at full level, and the edge must end cleanly.
    func testIncomingTrackThatNeverLoadsNeverRaisesAndNeverFades() throws {
        let player = try prepareOutgoing(fadeSeconds: 2)
        player.queue = [row(1), row(2, remoteURL: "https://example.invalid/never-loads.mp3")]

        sweep(player, through: 0...(outgoingSeconds + 0.5))

        XCTAssertFalse(player.transitionStartedForCurrentEdge)
        XCTAssertEqual(player.player.volume, player.outputLevel, "the outgoing track keeps full level")
        XCTAssertNil(player.crossfadePlayer, "the edge is released at the end of the outgoing track")
        XCTAssertEqual(player.index, 0, "the queue advances through the normal end-of-track path")
    }

    /// The normal case once the stream has loaded: the incoming track starts, the outgoing one
    /// fades, and the crossfade hands over the queue.
    func testIncomingTrackThatIsReadyBlendsAndHandsOver() throws {
        let player = try prepareOutgoing(fadeSeconds: 2)
        let incoming = row(2, remoteURL: "https://example.invalid/preloaded.mp3")
        player.queue = [row(1), incoming]
        player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
        player.preloadedNextTrackId = 2

        let fadeStart = outgoingSeconds - 2
        XCTAssertTrue(player.prepareCrossfadePlayer(for: incoming, at: 1))
        let crossfade = try XCTUnwrap(player.crossfadePlayer)
        XCTAssertTrue(waitUntil { isLoaded(crossfade) }, "local item should load")

        var sawBlend = false
        for position in stride(from: fadeStart, through: outgoingSeconds + 0.5, by: 0.1) {
            player.updateCrossfade(position: position)
            if player.index == 0, player.transitionStartedForCurrentEdge,
               player.player.volume < player.outputLevel, (player.crossfadePlayer?.volume ?? 0) > 0 {
                sawBlend = true
            }
            if player.index == 1 { break }
        }
        XCTAssertTrue(sawBlend, "both tracks should be audible together during the fade")
        XCTAssertEqual(player.index, 1, "the crossfade hands the queue to the incoming track")
    }

    /// Explicit Next must promote the prepared incoming item (same handoff as the natural
    /// boundary) instead of cancelling it and cold-rebuilding; it plays, with no failure banner.
    func testManualNextPromotesPreparedCrossfadeItem() throws {
        let player = try prepareOutgoing(fadeSeconds: 3)
        let incoming = row(2, remoteURL: "https://example.invalid/manual-next.mp3")
        player.queue = [row(1), incoming]
        player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
        player.preloadedNextTrackId = 2
        XCTAssertTrue(player.prepareCrossfadePlayer(for: incoming, at: 1))
        let prepared = try XCTUnwrap(player.crossfadePlayer)
        let preparedItem = try XCTUnwrap(prepared.currentItem)

        player.networkSkipMessage = nil // shared singleton: drop any banner left by earlier cases
        player.next()

        XCTAssertEqual(player.index, 1)
        XCTAssertTrue(player.player === prepared, "the prepared player becomes the active player")
        XCTAssertTrue(player.player.currentItem === preparedItem)
        XCTAssertNil(player.crossfadePlayer)
        XCTAssertTrue(player.isPlaying, "play intent is preserved")
        XCTAssertNil(player.networkSkipMessage)
    }

    /// With Smart Transitions gone, this plain crossfade is the only track-to-track transition
    /// left — the shipped default must already be a real, audible blend, not `0` (a silent
    /// hard cut) that a setting nobody has found yet would need to raise first.
    func testShippedDefaultCrossfadeSecondsProducesABlendWithoutAnyOverride() throws {
        XCTAssertEqual(savedCrossfade, 3, "the shipped default must be a real, nonzero blend")
        let player = try prepareOutgoing(fadeSeconds: savedCrossfade)
        let incoming = row(2, remoteURL: "https://example.invalid/default-blend.mp3")
        player.queue = [row(1), incoming]
        player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
        player.preloadedNextTrackId = 2

        let fadeStart = outgoingSeconds - savedCrossfade
        XCTAssertTrue(player.prepareCrossfadePlayer(for: incoming, at: 1))
        let crossfade = try XCTUnwrap(player.crossfadePlayer)
        XCTAssertTrue(waitUntil { isLoaded(crossfade) }, "local item should load")

        var sawBlend = false
        for position in stride(from: fadeStart, through: outgoingSeconds + 0.5, by: 0.1) {
            player.updateCrossfade(position: position)
            if player.index == 0, player.transitionStartedForCurrentEdge,
               player.player.volume < player.outputLevel, (player.crossfadePlayer?.volume ?? 0) > 0 {
                sawBlend = true
            }
            if player.index == 1 { break }
        }
        XCTAssertTrue(sawBlend, "both tracks should be audible together during the default blend")
        XCTAssertEqual(player.index, 1, "the default crossfade hands the queue to the incoming track")
    }

    /// The incoming track finishes loading partway through the fade window: the fade starts then.
    func testIncomingTrackThatLoadsMidFadeStartsLate() throws {
        let player = try prepareOutgoing(fadeSeconds: 4)
        let incoming = row(2, remoteURL: "https://example.invalid/late.mp3")
        player.queue = [row(1), incoming]
        player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
        player.preloadedNextTrackId = 2

        // First fade tick creates the incoming player before it has loaded: nothing may start.
        player.updateCrossfade(position: outgoingSeconds - 4)
        let crossfade = try XCTUnwrap(player.crossfadePlayer)
        if !isLoaded(crossfade) {
            XCTAssertFalse(player.transitionStartedForCurrentEdge)
            XCTAssertEqual(player.player.volume, player.outputLevel)
        }
        XCTAssertTrue(waitUntil { isLoaded(crossfade) })
        player.updateCrossfade(position: outgoingSeconds - 2)
        XCTAssertTrue(player.transitionStartedForCurrentEdge, "the fade starts once the track is ready")
    }

    /// Real report: the volume swelled and dropped repeatedly for minutes in the middle of a
    /// track. A remote/streamed item's live `AVPlayerItem.duration` estimate can change as more
    /// of the file loads — simulated here by setting `player.duration` far below the track's
    /// real, library-known length. The fade window must be computed from that stable library
    /// duration, not the fluctuating live one, so a mid-track position is never mistaken for
    /// "near the end."
    func testUnstableLiveDurationEstimateNeverDestabilizesTheFadeWindow() throws {
        let player = try prepareOutgoing(fadeSeconds: 2)
        let incoming = row(2, remoteURL: "https://example.invalid/next.mp3")
        player.queue = [row(1), incoming]
        // The real, library-known duration is outgoingSeconds (6s), fixed by `row(1)`'s
        // `durationSec`. A buggy live estimate of 3s would put the old code's fade window
        // starting at 1s (3 - 2 fadeSeconds) — well before the real fade window at 4s (6 - 2).
        player.duration = 3

        player.updateCrossfade(position: 2)
        XCTAssertEqual(player.player.volume, player.outputLevel,
            "position 2s must not be in the fade window — the real track is 6s long, not 3s")

        // Even once the live estimate "corrects" upward, it must still never win over the
        // library's own value.
        player.duration = 6
        player.updateCrossfade(position: 2)
        XCTAssertEqual(player.player.volume, player.outputLevel)
    }

    // MARK: - Helpers

    private func prepareOutgoing(fadeSeconds: Double) throws -> AudioPlayer {
        let player = AudioPlayer.shared
        player.cancelCrossfade(resetVolume: true)
        player.sleepAtEndOfTrack = false
        player.repeatMode = .off
        player.crossfadeSeconds = fadeSeconds
        // A previous case can leave the shared player playing its incoming track; these cases
        // drive the clock themselves, and the executor reads a playing player's own clock.
        player.player.pause()
        player.isPlaying = false
        let item = AVPlayerItem(url: try audioFile(seconds: outgoingSeconds))
        player.player.automaticallyWaitsToMinimizeStalling = false
        player.player.replaceCurrentItem(with: item)
        XCTAssertTrue(waitUntil { item.status == .readyToPlay }, "outgoing item should load")
        player.index = 0
        player.duration = outgoingSeconds
        return player
    }

    private func isLoaded(_ player: AVPlayer) -> Bool {
        player.status == .readyToPlay && player.currentItem?.status == .readyToPlay
    }

    private func sweep(_ player: AudioPlayer, through range: ClosedRange<Double>) {
        for position in stride(from: range.lowerBound, through: range.upperBound, by: 0.1) {
            player.updateCrossfade(position: position)
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
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
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        files.append(url)
        return url
    }
}
