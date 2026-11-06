import AVFoundation
import XCTest
@testable import TonearmCore

/// Integration coverage for `AudioPlayer.watchStallProgress`/`replaceItem` actually calling into
/// `StallModel` in production, not just `StallModel`'s own pure logic (already covered by
/// `Tests/PlaybackResilienceTests.swift`). `evaluateStall`/`markReady` were fully implemented and
/// unit-tested but never called in production until now — these tests pin the real wiring:
/// `replaceItem` begins a generation and marks it ready, and a track that's never confirmed
/// playing (the periodic observer's clock never genuinely advances) gets skipped once the
/// configured timeout elapses.
@MainActor
final class StallAutoSkipTests: XCTestCase {
    private let trackSeconds = 2.0
    private var files: [URL] = []
    private var savedKeepPlayingEnabled = true

    override func setUp() async throws {
        try await super.setUp()
        savedKeepPlayingEnabled = AudioPlayer.shared.keepPlayingEnabled
        // Deterministic "nowhere to skip to" path: with this on, a single-track queue could try
        // to extend itself via the real LibraryStore instead of just pausing.
        AudioPlayer.shared.keepPlayingEnabled = false
    }

    override func tearDown() async throws {
        let player = AudioPlayer.shared
        player.stallWatchTask?.cancel()
        player.player.pause()
        player.player.replaceCurrentItem(with: nil)
        player.queue = []
        player.index = 0
        player.isPlaying = false
        player.keepPlayingEnabled = savedKeepPlayingEnabled
        for file in files { try? FileManager.default.removeItem(at: file) }
        try await super.tearDown()
    }

    /// A single-track queue with nowhere to skip to: `next()` on an unconfirmed track just
    /// pauses, which is still an unambiguous, directly-observable signal that the stall watch
    /// fired and acted, without needing a second real asset to resolve.
    func testNeverConfirmedTrackIsSkippedAfterTheStallTimeoutAndPausesWithNowhereToGo() throws {
        let player = AudioPlayer.shared
        let savedTimeout = player.stallEvaluationTimeout
        defer { player.stallEvaluationTimeout = savedTimeout }
        player.stallEvaluationTimeout = .milliseconds(80)

        player.repeatMode = .off
        player.queue = [row(1)]
        player.index = 0

        let item = AVPlayerItem(url: try audioFile(seconds: trackSeconds))
        player.player.automaticallyWaitsToMinimizeStalling = false
        player.isPlaying = true
        player.replaceItem(item, autoplay: true)
        // Deliberately never confirmed: the real player never actually plays, so the periodic
        // time observer's clock never advances and `confirmPlayback` never fires.
        player.player.pause()

        XCTAssertTrue(waitUntil(timeout: 2) { player.isPlaying == false },
            "an unconfirmed autoplaying track with nowhere to skip to must pause, not hang forever")
    }

    /// The counterpart: a track that becomes ready and is never watched at all when it wasn't
    /// an autoplay load (the user loaded it paused) — nothing should happen at the timeout.
    func testManuallyPausedLoadIsNeverWatchedForStalling() throws {
        let player = AudioPlayer.shared
        let savedTimeout = player.stallEvaluationTimeout
        defer { player.stallEvaluationTimeout = savedTimeout }
        player.stallEvaluationTimeout = .milliseconds(80)

        player.repeatMode = .off
        player.queue = [row(1)]
        player.index = 0

        let item = AVPlayerItem(url: try audioFile(seconds: trackSeconds))
        player.isPlaying = false
        player.replaceItem(item, autoplay: false)

        XCTAssertNil(player.stallWatchTask, "a non-autoplaying load must never even start a stall watch")

        // Give the (never-started) watch a chance to have fired if it mistakenly started anyway.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(player.isPlaying, "a manually-paused load must stay exactly as the caller left it")
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private func row(_ id: Int64) -> TrackRow {
        let source = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil, title: "Test",
                            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                            licenseText: nil, memberCapHit: false)
        let track = Track(id: id, albumId: id, sourceId: 1, title: "Track \(id)", trackNo: nil, discNo: nil,
                          durationSec: trackSeconds, codec: "MP3", sampleRate: nil,
                          bitDepthOrBitrate: nil, sortKey: "\(id)")
        let asset = Asset(id: id, trackId: id, kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://example.invalid/track-\(id).mp3",
                          altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        return TrackRow(track: track, album: Album(id: id, sourceId: 1, title: "Album \(id)", artist: nil),
                        source: source, asset: asset)
    }

    /// A short silent audio file AVFoundation loads locally (no network in tests).
    private func audioFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stall-\(UUID().uuidString).caf")
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
