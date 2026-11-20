import AVFoundation
import Foundation
import Testing
@testable import TonearmCore

/// Drives the real `AudioPlayer` into a crossfade whose incoming track hasn't loaded yet — the
/// normal case for a remote stream. TestFlight 520 aborted when the incoming player was
/// driven before it was `.readyToPlay`; preparing it must leave it untouched until it has loaded.
extension SharedProductionSingletonTests {
    @MainActor
    /// Re-enabled (2026-11-19) — see `AudioPlayerJamendoLoadingTests`'s
    /// `@Suite` declaration and `Tests/SharedProductionSingletonTests.swift`.
    @Suite
    final class CrossfadePrepareTests {
        private let player = AudioPlayer.makeForTesting()
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

        @Test func testPreparingAnUnloadedIncomingTrackDoesNotPrerollBeforeItIsReady() {
            let row = remoteRow(9_001)

            #expect(player.prepareCrossfadePlayer(for: row, at: 1))
            #expect(player.crossfadeNextTrackId == 9_001)
            #expect(player.crossfadePlayer?.status != .readyToPlay)
            #expect(player.crossfadePlayer?.rate == 0, "an unloaded incoming track must not be started")

            // Every periodic tick re-enters with the same edge; it must stay safe while unloaded.
            for _ in 0..<5 { #expect(player.prepareCrossfadePlayer(for: row, at: 1)) }
            #expect(player.crossfadePlayer?.rate == 0)
        }

        /// Architecture-review finding: crossfade-prepare built its incoming item straight from a
        /// Jamendo row's raw, unresolved locator, the same defect as the near-gapless preload. A raw
        /// `jamendo://` item can never open, so the crossfade must never be prepared for one — the
        /// natural boundary falls back to the ordinary resolve path instead.
        @Test func testPrepareCrossfadePlayerNeverBuildsFromARawJamendoLocator() {
            let row = CatalogPlaybackURLResolverTests.row(kind: .local, nodeID: nil, url: "jamendo://track/55")

            #expect(!player.prepareCrossfadePlayer(for: row, at: 1),
                           "a Jamendo-locator row must never be crossfade-prepared from its raw, unresolved URL")
            #expect(player.crossfadePlayer == nil)
        }
    }
}
