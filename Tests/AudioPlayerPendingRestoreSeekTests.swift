#if !os(watchOS)
import AVFoundation
import XCTest
@testable import TonearmCore

/// Architecture-review finding: a restore-time seek target used to be a bare `Double?` with no
/// occurrence attached. If the restored track's resolve was still pending and the user loaded a
/// DIFFERENT track before it ever converged, the stale target kept reapplying to whatever loaded
/// next — reported as nonsensical elapsed times, and, if the target exceeded the new track's
/// length, a silent end-of-track skip.
@MainActor
final class AudioPlayerPendingRestoreSeekTests: XCTestCase {
    private let source = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil,
                                title: "S", addedAt: Date(), lastResolvedAt: nil,
                                followUpdates: false, licenseText: nil, memberCapHit: false)

    private func row(_ id: Int64, duration: Double = 180) -> TrackRow {
        let track = Track(id: id, albumId: nil, sourceId: 1, title: "T\(id)", trackNo: nil, discNo: nil,
                          durationSec: duration, codec: nil, sampleRate: nil, bitDepthOrBitrate: nil,
                          sortKey: "\(id)")
        let asset = Asset(id: id, trackId: id, kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://example.invalid/restore-seek-\(id).mp3", altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
        return TrackRow(track: track, album: nil, source: source, asset: asset)
    }

    override func tearDown() {
        let p = AudioPlayer.shared
        p.ordinaryBuildItemHook = nil
        p.clearQueuePlayback()
        p.queue = []
        super.tearDown()
    }

    func testStaleRestoreSeekNeverAppliesToADifferentlyLoadedTrack() {
        let player = AudioPlayer.shared
        player.ordinaryBuildItemHook = { _ in (AVPlayerItem(asset: AVMutableComposition()), nil) }
        player.keepPlayingEnabled = false
        player.queue = [row(1), row(2)]
        player.index = 0
        player.loadCurrent(autoplay: false)
        let staleOccurrence = player.queueOccurrences[0]
        // Simulate a restore that pinned a long target for track 1 before it ever converged
        // (e.g. its resolve was still pending when the app was backgrounded again).
        player.pendingRestoreSeek = (staleOccurrence, 1260)

        player.skipToIndex(1)

        XCTAssertNil(player.pendingRestoreSeek,
                     "a restore target recorded for a different track must never survive loading a different one")
    }

    func testRestoreSeekSurvivesReloadingTheSameOccurrence() {
        let player = AudioPlayer.shared
        player.ordinaryBuildItemHook = { _ in (AVPlayerItem(asset: AVMutableComposition()), nil) }
        player.keepPlayingEnabled = false
        player.queue = [row(1)]
        player.index = 0
        player.loadCurrent(autoplay: false)
        let occurrence = player.queueOccurrences[0]
        player.pendingRestoreSeek = (occurrence, 42)

        // Loading the exact same occurrence again (e.g. a redundant restore retry) must not
        // discard a still-valid pending target.
        player.loadCurrent(autoplay: false)

        XCTAssertEqual(player.pendingRestoreSeek?.seconds, 42)
    }
}
#endif
