import Foundation
import Testing
@testable import TonearmCore

/// Architecture-review finding: an unsupported-asset (or nil-`buildItem`) entry skipped straight
/// through `next()` → `loadCurrent()` → `next()` → ... with no base case. With every entry in the
/// queue unplayable and repeat-all on, that recursion has no stopping point and can overflow the
/// call stack. It must instead stop cleanly, with a visible reason, once every entry has had a
/// chance.
extension SharedProductionSingletonTests {
    @MainActor
    @Suite final class AudioPlayerUnplayableQueueTests {
        private let player = AudioPlayer()

        private func unsupportedRow(_ id: Int64) -> TrackRow {
            let source = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil, title: "S",
                                addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                                licenseText: nil, memberCapHit: false)
            let track = Track(id: id, albumId: nil, sourceId: 1, title: "T\(id)", trackNo: nil, discNo: nil,
                              durationSec: 180, codec: nil, sampleRate: nil, bitDepthOrBitrate: nil,
                              sortKey: "\(id)")
            let asset = Asset(id: id, trackId: id, kind: .remote, bookmark: nil, relPath: nil,
                              remoteURL: "https://example.invalid/unplayable-\(id).mp3", altRemoteURL: nil,
                              sizeBytes: nil, unsupportedReason: "codec")
            return TrackRow(track: track, album: nil, source: source, asset: asset)
        }

        @Test func testAllUnsupportedQueueWithRepeatAllStopsInsteadOfRecursingForever() {
            player.keepPlayingEnabled = false
            player.repeatMode = .all
            player.queue = [unsupportedRow(1), unsupportedRow(2)]
            player.index = 0
            player.networkSkipMessage = nil

            // Must return (not crash/stack-overflow) and leave the player cleanly stopped.
            player.loadCurrent(autoplay: true)

            #expect(!player.isPlaying)
            #expect(player.networkSkipMessage != nil)
        }
    }
}
