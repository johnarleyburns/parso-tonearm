import XCTest
@testable import TonearmCore

/// `RemoteTrackRowFactory.row` already sets `Asset.remoteContentType` on an in-memory,
/// just-browsed row (the one place Google Drive's `mimeType` survives, since its stream URL is
/// an extensionless `?alt=media` link). Real report: that hint was lost the moment the row got
/// persisted through `playRemote`/`toggleFavorite`/custom-artwork/watch-prep — `performPersistRemoteTrack`
/// built its own synthetic `RemoteNode` to hand to `RemotePlaylistIngest.persist` and never
/// carried `asset.remoteContentType` onto it, so the saved row lost the hint even though the
/// in-memory one it came from had it. The track then played fine once (streamed, in memory) but
/// failed the next time (cached-file replay, no format hint).
final class PersistRemoteTrackContentTypeTests: XCTestCase {
    @MainActor
    func testPersistRemoteTrackCarriesTheBrowsedRowsContentTypeOntoTheSavedAsset() async throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))
        let source = try await appState.store.insertSource(Source(
            id: nil, kind: .googleDrive, iaIdentifier: nil, originalURL: nil, title: "Drive",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let track = Track(id: -1, albumId: nil, sourceId: source.id!, title: "Song", trackNo: 1,
                           discNo: nil, durationSec: nil, codec: nil, sampleRate: nil,
                           bitDepthOrBitrate: nil, sortKey: "a")
        var asset = Asset(id: nil, trackId: -1, kind: .remote, bookmark: nil, relPath: nil,
                           remoteURL: "https://example.test/alt=media", altRemoteURL: nil,
                           sizeBytes: nil, unsupportedReason: nil)
        asset.remoteContentType = "audio/mp4"
        let row = TrackRow(track: track, album: nil, source: source, asset: asset)

        let persisted = try XCTUnwrap(await appState.persistRemoteTrack(row))

        XCTAssertGreaterThan(persisted.id, 0, "must be a real, persisted track id")
        XCTAssertEqual(persisted.asset?.remoteContentType, "audio/mp4")
    }
}
