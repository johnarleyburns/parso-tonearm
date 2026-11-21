#if !os(watchOS)
import AVFoundation
import Foundation
import Testing
@testable import TonearmCore

/// Ogg Opus is remuxed to CAF before playback. These tests cover detection,
/// the actual remux, and a full local `AudioPlayer` load that ends up playing
/// the generated CAF rather than the Ogg source.
@MainActor
@Suite struct OpusPlaybackPreparationTests {
    private func makeAsset(remoteURL: String? = nil, relPath: String? = nil,
                           nodePath: String? = nil,
                           opusRemoteURL: String? = nil,
                           contentType: String? = nil) -> Asset {
        Asset(id: 1, trackId: 1, kind: .localRef, bookmark: nil, relPath: relPath,
              remoteURL: remoteURL, altRemoteURL: nil,
              opusRemoteURL: opusRemoteURL, sizeBytes: 4096, unsupportedReason: nil,
              remoteNodePath: nodePath, remoteContentType: contentType)
    }

    @Test func testDetectsLocalAndRemoteOpusButNotMixedIAColdPlay() {
        #expect(OpusPlaybackPreparation.isOpusAsset(
            makeAsset(remoteURL: "file:///tmp/song.opus")))
        #expect(OpusPlaybackPreparation.isOpusAsset(
            makeAsset(relPath: "song.opus")))
        // Cloud rows resolve to extensionless URLs; the provider node path is
        // the stable hint that the underlying file is Ogg Opus.
        #expect(OpusPlaybackPreparation.isOpusAsset(
            makeAsset(remoteURL: "https://example.com/files/123?alt=media",
                      nodePath: "folder/song.opus")))
        #expect(OpusPlaybackPreparation.remoteSourceURL(
            for: makeAsset(remoteURL: "https://example.com/files/123?alt=media",
                           nodePath: "folder/song.opus"))?.absoluteString
            == "https://example.com/files/123?alt=media")
        #expect(OpusPlaybackPreparation.isOpusAsset(
            makeAsset(remoteURL: "https://example.com/song", contentType: "audio/opus")))
        #expect(OpusPlaybackPreparation.isOpusAsset(
            makeAsset(remoteURL: "https://example.com/song.opus")))
        // Mixed IA item: cold play is FLAC, Opus is only the upgrade derivative.
        #expect(!OpusPlaybackPreparation.isOpusAsset(
            makeAsset(remoteURL: "https://example.com/song.flac",
                      opusRemoteURL: "https://example.com/song.opus")))
        // Ogg Vorbis is not Opus and must not be sent to the Opus remuxer.
        #expect(!OpusPlaybackPreparation.isOpusAsset(
            makeAsset(remoteURL: "https://example.com/song.ogg", contentType: "audio/ogg")))
    }

    @Test func testLocalOpusRemuxesToPlayableCAF() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("opus-\(UUID().uuidString).opus")
        try Fixtures.data("tone_mono", ext: "opus").write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let caf = try await OpusPlaybackPreparation.prepare(
            source: source, cacheKey: AudioCache.key(for: source), headers: [:])
        defer { try? FileManager.default.removeItem(at: caf) }

        #expect(caf.pathExtension == "caf")
        #expect(FileManager.default.fileExists(atPath: caf.path))
        let data = try Data(contentsOf: caf)
        #expect(data.count > 0)
        #expect(data.prefix(4) == Data("caff".utf8), "remux must produce a CAF container")
    }

    @Test func testLocalOpusLoadEndsUpPlayingTheCAF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opus-player-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try Fixtures.data("tone_mono", ext: "opus")
        try bytes.write(to: directory.appendingPathComponent("song.opus"))

        let track = Track(id: 1, albumId: nil, sourceId: 1, title: "Opus",
                          trackNo: 1, discNo: nil, durationSec: 1, codec: "OPUS",
                          sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "opus")
        let asset = Asset(id: 1, trackId: 1, kind: .localRef, bookmark: nil,
                          relPath: "song.opus", remoteURL: nil, altRemoteURL: nil,
                          sizeBytes: Int64(bytes.count), unsupportedReason: nil)
        let row = TrackRow(track: track, album: nil, source: nil, asset: asset)

        let player = AudioPlayer.makeForTesting()
        player.keepPlayingEnabled = false
        // App-owned relPath resolution against this test's temp directory, so
        // the test never depends on security-scoped bookmarks in CI.
        player.localResolver.managedBase = { directory }
        player.queue = [row]
        player.index = 0
        player.loadCurrent(autoplay: false)

        let deadline = Date().addingTimeInterval(10)
        while player.player.currentItem == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let item = try #require(player.player.currentItem)
        let url = try #require((item.asset as? AVURLAsset)?.url)
        #expect(url.pathExtension == "caf",
                "a local .opus load must prepare and play the remuxed CAF")
    }

    @Test func testLocalImportAcceptsOpus() {
        #expect(IngestService.audioExtensions.contains("opus"))
    }
}
#endif
