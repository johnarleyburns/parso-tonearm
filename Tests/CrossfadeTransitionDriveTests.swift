import AVFoundation
import XCTest
@testable import TonearmCore

/// Drives the real `AudioPlayer` through whole crossfades, tick by tick, the way the periodic
/// time observer does during a mix. TestFlight 520 and 521 both aborted mid-mix on an
/// Objective-C exception from an AVPlayer call made before the incoming track had loaded
/// (`preroll`, then `setRate(_:time:atHostTime:)`). XCTest reports such an exception as a failure,
/// so each case here fails loudly if any transition path can raise again.
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
        player.transitionPlan = nil
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

    /// A beat-matched plan takes the synchronized-start and rate-ramp path; an unloaded incoming
    /// track must not reach it either.
    func testBeatmatchedPlanWithAnUnloadedIncomingTrackNeverRaises() throws {
        let player = try prepareOutgoing(fadeSeconds: 2)
        player.queue = [row(1), row(2, remoteURL: "https://example.invalid/never-loads-2.mp3")]
        player.transitionPlan = TransitionPlan(fromTrackID: 1, toTrackID: 2, style: .beatmatchedBlend,
                                               exitTime: 3, entryTime: 0.5, overlapBeats: 4,
                                               overlapSeconds: 2, blendRate: 1.03, rateRampBeats: 4)

        sweep(player, through: 0...(outgoingSeconds + 0.5))

        XCTAssertFalse(player.transitionStartedForCurrentEdge)
        XCTAssertNil(player.crossfadePlayer)
    }

    /// The normal case once the stream has loaded: the incoming track is started with a
    /// synchronized start, the outgoing one fades, and the crossfade hands over the queue.
    func testIncomingTrackThatIsReadyBlendsAndHandsOver() throws {
        let player = try prepareOutgoing(fadeSeconds: 2)
        let incoming = row(2, remoteURL: "https://example.invalid/preloaded.mp3")
        player.queue = [row(1), incoming]
        player.preloadedNextItem = AVPlayerItem(url: try audioFile(seconds: 6))
        player.preloadedNextTrackId = 2

        let fadeStart = outgoingSeconds - 2
        XCTAssertTrue(player.prepareCrossfadePlayer(for: incoming, at: 1))
        let crossfade = try XCTUnwrap(player.crossfadePlayer)
        XCTAssertTrue(waitUntil { TransitionPlayerControl.isReady(crossfade) }, "local item should load")

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
        if !TransitionPlayerControl.isReady(crossfade) {
            XCTAssertFalse(player.transitionStartedForCurrentEdge)
            XCTAssertEqual(player.player.volume, player.outputLevel)
        }
        XCTAssertTrue(waitUntil { TransitionPlayerControl.isReady(crossfade) })
        player.updateCrossfade(position: outgoingSeconds - 2)
        XCTAssertTrue(player.transitionStartedForCurrentEdge, "the fade starts once the track is ready")
    }

    // MARK: - TransitionPlayerControl

    func testControlRefusesEveryUnreadyPlayerWithoutRaising() {
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        let unloaded = AVPlayer(playerItem: AVPlayerItem(url: URL(string: "https://example.invalid/x.mp3")!))
        unloaded.automaticallyWaitsToMinimizeStalling = false
        let empty = AVPlayer()
        empty.automaticallyWaitsToMinimizeStalling = false
        for candidate in [unloaded, empty, AVPlayer()] {
            XCTAssertFalse(TransitionPlayerControl.isReady(candidate))
            XCTAssertFalse(TransitionPlayerControl.preroll(candidate, rate: 1))
            XCTAssertFalse(TransitionPlayerControl.schedule(candidate, rate: 1, itemTime: .zero, hostTime: host))
        }
    }

    func testControlSchedulesAReadyPlayerAndRejectsUnusableArguments() throws {
        let ready = AVPlayer(playerItem: AVPlayerItem(url: try audioFile(seconds: 3)))
        ready.automaticallyWaitsToMinimizeStalling = false
        XCTAssertTrue(waitUntil { TransitionPlayerControl.isReady(ready) })
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        XCTAssertFalse(TransitionPlayerControl.schedule(ready, rate: .nan, itemTime: .zero, hostTime: host))
        XCTAssertFalse(TransitionPlayerControl.schedule(ready, rate: 1, itemTime: .invalid, hostTime: host))
        XCTAssertTrue(TransitionPlayerControl.preroll(ready, rate: 1))
        XCTAssertTrue(TransitionPlayerControl.schedule(
            ready, rate: 1, itemTime: .zero,
            hostTime: CMTimeAdd(host, CMTime(seconds: 0.2, preferredTimescale: 600))))
        ready.pause()
    }

    // MARK: - Helpers

    private func prepareOutgoing(fadeSeconds: Double) throws -> AudioPlayer {
        let player = AudioPlayer.shared
        player.cancelCrossfade(resetVolume: true)
        player.transitionPlan = nil
        player.sleepAtEndOfTrack = false
        player.repeatMode = .off
        player.crossfadeSeconds = fadeSeconds
        let item = AVPlayerItem(url: try audioFile(seconds: outgoingSeconds))
        player.player.automaticallyWaitsToMinimizeStalling = false
        player.player.replaceCurrentItem(with: item)
        XCTAssertTrue(waitUntil { item.status == .readyToPlay }, "outgoing item should load")
        // A timebase sends the transition down the synchronized-start path that crashed.
        XCTAssertNotNil(player.player.currentItem?.timebase)
        player.index = 0
        player.duration = outgoingSeconds
        return player
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
