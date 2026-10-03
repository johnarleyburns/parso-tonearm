import AVFoundation
import XCTest
@testable import TonearmCore

/// Drives the real `AudioPlayer` into a crossfade whose incoming track hasn't loaded yet — the
/// normal case for a remote stream. TestFlight 520 aborted here: `AVPlayer.preroll(atRate:)`
/// raises an Objective-C exception unless the player is `.readyToPlay`, and a test that hits it
/// crashes the test process, so this fails loudly if that call comes back.
@MainActor
final class CrossfadePrepareTests: XCTestCase {
    private let source = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil,
                                title: "Test Source", addedAt: Date(), lastResolvedAt: nil,
                                followUpdates: false, licenseText: nil, memberCapHit: false)

    private func remoteRow(_ id: Int64) -> TrackRow {
        let track = Track(id: id, albumId: 1, sourceId: 1, title: "Track \(id)", trackNo: nil, discNo: nil,
                          durationSec: 180, codec: "MP3", sampleRate: nil, bitDepthOrBitrate: nil,
                          sortKey: "\(id)")
        let asset = Asset(id: id, trackId: id, kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://example.invalid/crossfade-\(id).mp3", altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
        return TrackRow(track: track, album: Album(id: 1, sourceId: 1, title: "Folk", artist: nil),
                        source: source, asset: asset)
    }

    override func tearDown() {
        MainActor.assumeIsolated { AudioPlayer.shared.cancelCrossfade(resetVolume: true) }
        super.tearDown()
    }

    func testPreparingAnUnloadedIncomingTrackDoesNotPrerollBeforeItIsReady() {
        let player = AudioPlayer.shared
        let row = remoteRow(9_001)

        XCTAssertTrue(player.prepareCrossfadePlayer(for: row, at: 1))
        XCTAssertEqual(player.crossfadeNextTrackId, 9_001)
        XCTAssertNotEqual(player.crossfadePlayer?.status, .readyToPlay)
        XCTAssertFalse(player.crossfadePrerolled, "preroll must wait for .readyToPlay")

        // Every periodic tick re-enters with the same edge; it must stay safe while unloaded.
        for _ in 0..<5 { XCTAssertTrue(player.prepareCrossfadePlayer(for: row, at: 1)) }
        XCTAssertFalse(player.crossfadePrerolled)
    }

    func testPrerollOnlyRunsForAReadyPlayer() {
        let unloaded = AVPlayer(playerItem: AVPlayerItem(url: URL(string: "https://example.invalid/a.mp3")!))
        XCTAssertFalse(AudioPlayer.prerollIfReady(unloaded, rate: 1))
    }
}
