import XCTest
@testable import TonearmCore

@MainActor
final class RemotePlaybackMetadataTests: XCTestCase {
    func testMockProvidersBuildPlayableRowsWithoutDroppingSourceMetadata() async throws {
        for kind in RemoteLibraryAccessPolicy.productSourceKinds {
            let source = Source(
                id: nil,
                kind: kind,
                iaIdentifier: nil,
                originalURL: nil,
                title: RemoteConnectorCatalog.displayName(kind),
                addedAt: Date(timeIntervalSince1970: 1),
                lastResolvedAt: nil,
                followUpdates: false,
                licenseText: nil,
                memberCapHit: false
            )
            let metadata = richMetadata(for: kind)
            let node = RemoteNode(
                id: "audio-\(kind.rawValue)",
                title: metadata?.title ?? "Track.flac",
                path: "track/\(kind.rawValue)",
                kind: .audio,
                sizeBytes: 4096,
                durationSec: 180,
                metadata: metadata
            )
            let provider = StaticRemoteProvider(sourceKind: kind, node: node, resolved: resolvedAsset(for: kind, metadata: metadata))

            let browsed = try await provider.browse(path: "")
            let audio = try XCTUnwrap(browsed.first)
            let resolved = try await provider.resolve(node: audio)
            let row = RemoteTrackRowFactory.row(source: source, node: audio, resolved: resolved, index: 0)

            XCTAssertEqual(row.source?.kind, kind)
            XCTAssertEqual(row.source?.title, source.title)
            XCTAssertEqual(row.asset?.transientRemoteHeaders["X-Test-Provider"], kind.rawValue)
            XCTAssertEqual(row.asset?.transientRemoteSupportsByteRanges, kind != .smb)

            if [.subsonic, .jellyfin, .plex].contains(kind) {
                XCTAssertEqual(row.album?.title, "Field Test Album")
                XCTAssertEqual(row.album?.artist, "Field Test Artist")
                XCTAssertEqual(row.track.trackNo, 7)
                XCTAssertEqual(row.track.codec, "FLAC")
                XCTAssertEqual(row.album?.artworkId, "\(kind.rawValue):cover")
            } else {
                XCTAssertNil(row.album)
                XCTAssertEqual(row.track.title, "Track.flac")
            }

            AudioPlayer.shared.play(tracks: [row], startAt: 0, source: .source(source))
            XCTAssertEqual(AudioPlayer.shared.currentTrack?.source?.kind, kind)
            XCTAssertEqual(AudioPlayer.shared.currentTrack?.asset?.transientRemoteHeaders["X-Test-Provider"], kind.rawValue)
        }
    }

    func testMiniplayerDisplayPolicyUsesProviderNamesAndCacheState() {
        let archiveRow = row(kind: .iaItem, assetKind: .remote)
        XCTAssertEqual(
            PlaybackDisplayPolicy.miniPlayerSubtitle(
                row: archiveRow,
                cacheState: .none,
                shuffle: false,
                repeatMode: .off
            ),
            "archive.org"
        )
        XCTAssertEqual(
            PlaybackDisplayPolicy.miniPlayerSubtitle(
                row: archiveRow,
                cacheState: .cached,
                shuffle: false,
                repeatMode: .off
            ),
            "archive.org · cached"
        )

        let subsonicRow = row(kind: .subsonic, assetKind: .remote)
        XCTAssertEqual(
            PlaybackDisplayPolicy.miniPlayerSubtitle(
                row: subsonicRow,
                cacheState: .filling(0.5),
                shuffle: true,
                repeatMode: .all
            ),
            "Shuffled · Repeat All · Subsonic · caching..."
        )
    }

    private func richMetadata(for kind: SourceKind) -> RemoteTrackMetadata? {
        guard [.subsonic, .jellyfin, .plex].contains(kind) else { return nil }
        return RemoteTrackMetadata(
            title: "Field Test Track",
            artist: "Field Test Artist",
            album: "Field Test Album",
            albumArtist: "Field Test Artist",
            trackNumber: 7,
            discNumber: 1,
            durationSec: 180,
            codec: "flac",
            sampleRate: 44_100,
            bitRateKbps: 900,
            genre: "Ambient",
            artwork: RemoteArtwork(
                id: "\(kind.rawValue):cover",
                url: URL(string: "https://example.com/\(kind.rawValue)/cover.jpg"),
                headers: ["X-Test-Provider": kind.rawValue]
            )
        )
    }

    private func resolvedAsset(for kind: SourceKind, metadata: RemoteTrackMetadata?) -> ResolvedAsset {
        ResolvedAsset(
            url: URL(string: "https://example.com/\(kind.rawValue)/track.flac")!,
            headers: ["X-Test-Provider": kind.rawValue],
            supportsByteRanges: kind != .smb,
            sizeBytes: 4096,
            metadata: metadata
        )
    }

    private func row(kind: SourceKind, assetKind: AssetKind) -> TrackRow {
        let source = Source(
            id: 1,
            kind: kind,
            iaIdentifier: nil,
            originalURL: nil,
            title: "Source",
            addedAt: Date(timeIntervalSince1970: 1),
            lastResolvedAt: nil,
            followUpdates: false,
            licenseText: nil,
            memberCapHit: false
        )
        let track = Track(
            id: 1,
            albumId: nil,
            sourceId: 1,
            title: "Track",
            trackNo: 1,
            discNo: nil,
            durationSec: 60,
            codec: "MP3",
            sampleRate: nil,
            bitDepthOrBitrate: nil,
            sortKey: "1"
        )
        let asset = Asset(
            id: 1,
            trackId: 1,
            kind: assetKind,
            bookmark: nil,
            relPath: nil,
            remoteURL: "https://example.com/track.mp3",
            altRemoteURL: nil,
            sizeBytes: nil,
            unsupportedReason: nil
        )
        return TrackRow(track: track, album: nil, source: source, asset: asset)
    }

    private struct StaticRemoteProvider: RemoteLibraryProvider {
        var sourceKind: SourceKind
        var node: RemoteNode
        var resolved: ResolvedAsset

        func browse(path: String) async throws -> [RemoteNode] {
            [node]
        }

        func resolve(node: RemoteNode) async throws -> ResolvedAsset {
            resolved
        }

        func refresh() async throws {}
    }
}
