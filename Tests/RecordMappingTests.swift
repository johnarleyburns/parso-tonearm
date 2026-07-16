import XCTest
import CloudKit
@testable import TonearmCore

/// C7 — pure round-trips between GRDB domain rows and `CKRecord`s. No networked
/// CloudKit; asserts parent-ref integrity via `syncID` and local-bookmark omission.
final class RecordMappingTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    func testSourceRoundTrips() {
        let source = Source(id: 1, kind: .iaItem, iaIdentifier: "gd77", originalURL: "https://archive.org/x",
                            title: "Show", addedAt: Date(timeIntervalSince1970: 1000),
                            lastResolvedAt: nil, followUpdates: true, licenseText: "CC",
                            memberCapHit: false, localIsFolder: false, artworkTrackId: 9,
                            syncID: "SRC-1")
        let record = RecordMapping.record(from: source, zoneID: zoneID)
        let decoded = RecordMapping.source(from: record)
        XCTAssertEqual(decoded?.syncID, "SRC-1")
        XCTAssertEqual(decoded?.kind, .iaItem)
        XCTAssertEqual(decoded?.title, "Show")
        XCTAssertEqual(decoded?.followUpdates, true)
        XCTAssertEqual(decoded?.iaIdentifier, "gd77")
    }

    func testAlbumCarriesParentSourceSyncID() {
        let album = Album(id: 2, sourceId: 1, title: "Set I", artist: "GD", year: 1977,
                          artworkId: "art", syncID: "ALB-1")
        let record = RecordMapping.record(from: album, sourceSyncID: "SRC-1", zoneID: zoneID)
        let decoded = RecordMapping.album(from: record)
        XCTAssertEqual(decoded?.album.syncID, "ALB-1")
        XCTAssertEqual(decoded?.album.title, "Set I")
        XCTAssertEqual(decoded?.sourceSyncID, "SRC-1")
    }

    func testTrackCarriesParentRefs() {
        let track = Track(id: 3, albumId: 2, sourceId: 1, title: "Jam", trackNo: 4, discNo: 1,
                          durationSec: 620, codec: "flac", sampleRate: 44100,
                          bitDepthOrBitrate: "16", sortKey: "0004",
                          rgTrackGain: -6.54, rgAlbumGain: -5.25,
                          rgTrackPeak: 0.91, rgAlbumPeak: 0.98,
                          syncID: "TRK-1")
        let record = RecordMapping.record(from: track, sourceSyncID: "SRC-1",
                                          albumSyncID: "ALB-1", zoneID: zoneID)
        let decoded = RecordMapping.track(from: record)
        XCTAssertEqual(decoded?.track.syncID, "TRK-1")
        XCTAssertEqual(decoded?.sourceSyncID, "SRC-1")
        XCTAssertEqual(decoded?.albumSyncID, "ALB-1")
        XCTAssertEqual(decoded?.track.durationSec, 620)
        XCTAssertEqual(decoded?.track.rgTrackGain, -6.54)
        XCTAssertEqual(decoded?.track.rgAlbumGain, -5.25)
        XCTAssertEqual(decoded?.track.rgTrackPeak, 0.91)
        XCTAssertEqual(decoded?.track.rgAlbumPeak, 0.98)
    }

    func testAssetOmitsLocalBookmark() {
        let asset = Asset(id: 4, trackId: 3, kind: .localRef, bookmark: Data([1, 2, 3]),
                          relPath: "a.flac", remoteURL: nil, altRemoteURL: nil,
                          opusRemoteURL: nil, sizeBytes: 100, unsupportedReason: nil,
                          needsReimport: false, syncID: "AST-1")
        let record = RecordMapping.record(from: asset, trackSyncID: "TRK-1", zoneID: zoneID)
        XCTAssertNil(record["bookmark"], "device-specific bookmark must never sync")
        let decoded = RecordMapping.asset(from: record)
        XCTAssertNil(decoded?.asset.bookmark)
        XCTAssertEqual(decoded?.trackSyncID, "TRK-1")
        // A local-ref with no remote URL is flagged for re-import on pull (C4).
        XCTAssertEqual(decoded?.asset.needsReimport, true)
    }

    func testRemoteAssetDoesNotNeedReimport() {
        let asset = Asset(id: 5, trackId: 3, kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/a.mp3", altRemoteURL: nil,
                          opusRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil,
                          needsReimport: false, syncID: "AST-2")
        let record = RecordMapping.record(from: asset, trackSyncID: "TRK-1", zoneID: zoneID)
        let decoded = RecordMapping.asset(from: record)
        XCTAssertEqual(decoded?.asset.needsReimport, false)
    }

    func testPlaylistOmitsFolderBookmark() {
        let playlist = Playlist(id: 6, title: "Faves", kind: .manual,
                                folderBookmark: Data([9]), watch: false, syncID: "PL-1")
        let record = RecordMapping.record(from: playlist, zoneID: zoneID)
        XCTAssertNil(record["folderBookmark"])
        let decoded = RecordMapping.playlist(from: record)
        XCTAssertEqual(decoded?.syncID, "PL-1")
        XCTAssertEqual(decoded?.title, "Faves")
    }

    func testPlaylistItemCarriesParentRefs() {
        let item = PlaylistItem(id: 7, playlistId: 6, position: 2, trackId: 3,
                                sectionTitle: "Encore", syncID: "PLI-1")
        let record = RecordMapping.record(from: item, playlistSyncID: "PL-1",
                                          trackSyncID: "TRK-1", zoneID: zoneID)
        let decoded = RecordMapping.playlistItem(from: record)
        XCTAssertEqual(decoded?.item.position, 2)
        XCTAssertEqual(decoded?.playlistSyncID, "PL-1")
        XCTAssertEqual(decoded?.trackSyncID, "TRK-1")
    }

    func testFavoriteRoundTrips() {
        let fav = Favorite(id: 8, trackId: 3, favoritedAt: Date(timeIntervalSince1970: 5),
                           syncID: "FAV-1")
        let record = RecordMapping.record(from: fav, trackSyncID: "TRK-1", zoneID: zoneID)
        let decoded = RecordMapping.favorite(from: record)
        XCTAssertEqual(decoded?.favorite.syncID, "FAV-1")
        XCTAssertEqual(decoded?.trackSyncID, "TRK-1")
    }

    func testPlayEventRoundTrips() {
        let event = PlayEvent(id: 9, trackId: 3, playedAt: Date(timeIntervalSince1970: 42),
                              syncID: "PE-1")
        let record = RecordMapping.record(from: event, trackSyncID: "TRK-1", zoneID: zoneID)
        let decoded = RecordMapping.playEvent(from: record)
        XCTAssertEqual(decoded?.event.syncID, "PE-1")
        XCTAssertEqual(decoded?.event.playedAt, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(decoded?.trackSyncID, "TRK-1")
    }

    func testCustomArtworkRoundTripsWithoutImage() {
        let art = CustomArtworkRecord(syncID: "CA-1", artworkId: "abc.jpg")
        let record = RecordMapping.record(from: art, trackSyncID: "TRK-1", fileURL: nil, zoneID: zoneID)
        let decoded = RecordMapping.customArtwork(from: record)
        XCTAssertEqual(decoded?.artwork.syncID, "CA-1")
        XCTAssertEqual(decoded?.artwork.artworkId, "abc.jpg")
        XCTAssertEqual(decoded?.trackSyncID, "TRK-1")
        XCTAssertNil(decoded?.imageURL)
    }

    func testAppSettingsRoundTrips() {
        let settings = SyncedSettings(
            eqEnabled: true,
            eqGains: Array(repeating: 1.5, count: EQEngine.bandCount),
            userPresets: [EQPreset(name: "Mine", gains: Array(repeating: 2, count: EQEngine.bandCount), isBuiltIn: false)],
            preferFLAC: true, prefetchDepth: 3, streamOnCellular: false, artworkLookup: true)
        let record = RecordMapping.record(from: settings, zoneID: zoneID)
        XCTAssertEqual(record.recordID.recordName, RecordMapping.appSettingsRecordName)
        let decoded = RecordMapping.syncedSettings(from: record)
        XCTAssertEqual(decoded, settings)
    }
}
