import Testing
import CloudKit
@testable import TonearmCore

/// C7 — pure round-trips between GRDB domain rows and `CKRecord`s. No networked
/// CloudKit; asserts parent-ref integrity via `syncID` and local-bookmark omission.
@Suite struct RecordMappingTests {

    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    @Test func testSourceRoundTrips() {
        let source = Source(id: 1, kind: .iaItem, iaIdentifier: "gd77", originalURL: "https://archive.org/x",
                            title: "Show", addedAt: Date(timeIntervalSince1970: 1000),
                            lastResolvedAt: nil, followUpdates: true, licenseText: "CC",
                            memberCapHit: false, localIsFolder: false, artworkTrackId: 9,
                            syncID: "SRC-1")
        let record = RecordMapping.record(from: source, zoneID: zoneID)
        let decoded = RecordMapping.source(from: record)
        #expect(decoded?.syncID == "SRC-1")
        #expect(decoded?.kind == .iaItem)
        #expect(decoded?.title == "Show")
        #expect(decoded?.followUpdates == true)
        #expect(decoded?.iaIdentifier == "gd77")
    }

    @Test func testAlbumCarriesParentSourceSyncID() {
        let album = Album(id: 2, sourceId: 1, title: "Set I", artist: "GD", year: 1977,
                          artworkId: "art", syncID: "ALB-1")
        let record = RecordMapping.record(from: album, sourceSyncID: "SRC-1", zoneID: zoneID)
        let decoded = RecordMapping.album(from: record)
        #expect(decoded?.album.syncID == "ALB-1")
        #expect(decoded?.album.title == "Set I")
        #expect(decoded?.sourceSyncID == "SRC-1")
    }

    @Test func testTrackCarriesParentRefs() {
        let track = Track(id: 3, albumId: 2, sourceId: 1, title: "Jam", trackNo: 4, discNo: 1,
                          durationSec: 620, codec: "flac", sampleRate: 44100,
                          bitDepthOrBitrate: "16", sortKey: "0004",
                          rgTrackGain: -6.54, rgAlbumGain: -5.25,
                          rgTrackPeak: 0.91, rgAlbumPeak: 0.98,
                          syncID: "TRK-1")
        let record = RecordMapping.record(from: track, sourceSyncID: "SRC-1",
                                          albumSyncID: "ALB-1", zoneID: zoneID)
        let decoded = RecordMapping.track(from: record)
        #expect(decoded?.track.syncID == "TRK-1")
        #expect(decoded?.sourceSyncID == "SRC-1")
        #expect(decoded?.albumSyncID == "ALB-1")
        #expect(decoded?.track.durationSec == 620)
        #expect(decoded?.track.rgTrackGain == -6.54)
        #expect(decoded?.track.rgAlbumGain == -5.25)
        #expect(decoded?.track.rgTrackPeak == 0.91)
        #expect(decoded?.track.rgAlbumPeak == 0.98)
    }

    @Test func testAssetOmitsLocalBookmark() {
        let asset = Asset(id: 4, trackId: 3, kind: .localRef, bookmark: Data([1, 2, 3]),
                          relPath: "a.flac", remoteURL: nil, altRemoteURL: nil,
                          opusRemoteURL: nil, sizeBytes: 100, unsupportedReason: nil,
                          needsReimport: false, syncID: "AST-1")
        let record = RecordMapping.record(from: asset, trackSyncID: "TRK-1", zoneID: zoneID)
        #expect(record["bookmark"] == nil, "device-specific bookmark must never sync")
        let decoded = RecordMapping.asset(from: record)
        #expect(decoded?.asset.bookmark == nil)
        #expect(decoded?.trackSyncID == "TRK-1")
        // A local-ref with no remote URL is flagged for re-import on pull (C4).
        #expect(decoded?.asset.needsReimport == true)
    }

    @Test func testRemoteAssetDoesNotNeedReimport() {
        let asset = Asset(id: 5, trackId: 3, kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/a.mp3", altRemoteURL: nil,
                          opusRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil,
                          needsReimport: false, syncID: "AST-2")
        let record = RecordMapping.record(from: asset, trackSyncID: "TRK-1", zoneID: zoneID)
        let decoded = RecordMapping.asset(from: record)
        #expect(decoded?.asset.needsReimport == false)
    }

    @Test func testPlaylistOmitsFolderBookmark() {
        let playlist = Playlist(id: 6, title: "Faves", kind: .manual,
                                folderBookmark: Data([9]), watch: false,
                                isInCrate: true, syncID: "PL-1")
        let record = RecordMapping.record(from: playlist, zoneID: zoneID)
        #expect(record["folderBookmark"] == nil)
        let decoded = RecordMapping.playlist(from: record)
        #expect(decoded?.syncID == "PL-1")
        #expect(decoded?.title == "Faves")
        #expect(decoded?.isInCrate == true)
    }

    @Test func testPlaylistItemCarriesParentRefs() {
        let item = PlaylistItem(id: 7, playlistId: 6, position: 2, trackId: 3,
                                sectionTitle: "Encore", syncID: "PLI-1")
        let record = RecordMapping.record(from: item, playlistSyncID: "PL-1",
                                          trackSyncID: "TRK-1", zoneID: zoneID)
        let decoded = RecordMapping.playlistItem(from: record)
        #expect(decoded?.item.position == 2)
        #expect(decoded?.playlistSyncID == "PL-1")
        #expect(decoded?.trackSyncID == "TRK-1")
    }

    @Test func testFavoriteRoundTrips() {
        let fav = Favorite(id: 8, trackId: 3, favoritedAt: Date(timeIntervalSince1970: 5),
                           syncID: "FAV-1")
        let record = RecordMapping.record(from: fav, trackSyncID: "TRK-1", zoneID: zoneID)
        let decoded = RecordMapping.favorite(from: record)
        #expect(decoded?.favorite.syncID == "FAV-1")
        #expect(decoded?.trackSyncID == "TRK-1")
    }

    @Test func testPlayEventRoundTrips() {
        let event = PlayEvent(id: 9, trackId: 3, playedAt: Date(timeIntervalSince1970: 42),
                              syncID: "PE-1")
        let record = RecordMapping.record(from: event, trackSyncID: "TRK-1", zoneID: zoneID)
        let decoded = RecordMapping.playEvent(from: record)
        #expect(decoded?.event.syncID == "PE-1")
        #expect(decoded?.event.playedAt == Date(timeIntervalSince1970: 42))
        #expect(decoded?.trackSyncID == "TRK-1")
    }

    @Test func testCustomArtworkRoundTripsWithoutImage() {
        let art = CustomArtworkRecord(syncID: "CA-1", artworkId: "abc.jpg")
        let record = RecordMapping.record(from: art, trackSyncID: "TRK-1", fileURL: nil, zoneID: zoneID)
        let decoded = RecordMapping.customArtwork(from: record)
        #expect(decoded?.artwork.syncID == "CA-1")
        #expect(decoded?.artwork.artworkId == "abc.jpg")
        #expect(decoded?.trackSyncID == "TRK-1")
        #expect(decoded?.imageURL == nil)
    }

    @Test func testDiscoveryEmbeddingRoundTrips() {
        let embedding = DiscoveryEmbedding(
            trackId: 3, assetId: 4, assetRevision: 1, modelVersion: 1,
            preprocessingVersion: 1, samplingVersion: 1, dimensions: 4,
            quantizedVector: Data([1, 2, 3, 4]), scale: 0.01,
            completedAt: Date(timeIntervalSince1970: 100), syncID: "EMB-1")
        let record = RecordMapping.record(from: embedding, trackSyncID: "TRK-1", zoneID: zoneID)
        #expect(record["assetId"] == nil, "device-local asset identity must never sync")
        let decoded = RecordMapping.discoveryEmbedding(from: record)
        #expect(decoded?.embedding.syncID == "EMB-1")
        #expect(decoded?.embedding.dimensions == 4)
        #expect(decoded?.embedding.quantizedVector == Data([1, 2, 3, 4]))
        #expect(decoded?.embedding.scale == 0.01)
        #expect(decoded?.trackSyncID == "TRK-1")
    }

    @Test func testDiscoveryTrackAnalysisRoundTrips() {
        let analysis = DiscoveryTrackAnalysis(
            trackId: 3, assetId: 4, assetRevision: 1, analysisVersion: 1,
            bpm: 128, key: "Am", energy: 0.8, phraseSummary: "verse-chorus",
            analysisScopeSeconds: 60, completedAt: Date(timeIntervalSince1970: 200),
            syncID: "ANA-1")
        let record = RecordMapping.record(from: analysis, trackSyncID: "TRK-1", zoneID: zoneID)
        let decoded = RecordMapping.discoveryTrackAnalysis(from: record)
        #expect(decoded?.analysis.syncID == "ANA-1")
        #expect(decoded?.analysis.bpm == 128)
        #expect(decoded?.analysis.key == "Am")
        #expect(decoded?.analysis.phraseSummary == "verse-chorus")
        #expect(decoded?.trackSyncID == "TRK-1")
    }

    /// `RecordMapping.djTrackPrep(from:)` is decode-only now (nothing in this app ever enqueues a
    /// `DJTrackPrep` record to push — `enqueueDJTrackPrep` was removed as dead code), so there's
    /// no more encode half to round-trip against; this builds the `CKRecord` a legacy remote
    /// record from an old app version's sync history would look like, by hand.
    @Test func testDJTrackPrepDecodesIdentityAndKeptFields() {
        let keys = [TrackIdentityKey(strength: .source, value: "source-hash"),
                    TrackIdentityKey(strength: .meta, value: "meta-hash")]
        let record = CKRecord(recordType: RecordMapping.RecordType.djTrackPrep.rawValue,
                              recordID: RecordMapping.recordID(type: .djTrackPrep, syncID: "PREP-1", zoneID: zoneID))
        record["syncID"] = "PREP-1" as CKRecordValue
        record["trackSyncID"] = "TRK-1" as CKRecordValue
        record["trackKeys"] = keys.map(\.cloudValue) as CKRecordValue
        record["bpm"] = 128.0 as CKRecordValue
        record["camelotKey"] = "8B" as CKRecordValue
        record["analysisUpdatedAt"] = Date(timeIntervalSince1970: 11) as CKRecordValue
        record["bpmOverride"] = 130.0 as CKRecordValue
        // A legacy field this app never reads anymore — present on a real old record, and must
        // not prevent decoding the fields that still matter.
        record["hotCues"] = "{\"1\":2.5}" as CKRecordValue

        let decoded = RecordMapping.djTrackPrep(from: record)
        #expect(decoded?.prep.syncID == "PREP-1")
        #expect(decoded?.prep.bpm == 128)
        #expect(decoded?.prep.camelotKey == "8B")
        #expect(decoded?.prep.analysisUpdatedAt == Date(timeIntervalSince1970: 11))
        #expect(decoded?.prep.bpmOverride == 130)
        #expect(decoded?.trackSyncID == "TRK-1")
        #expect(decoded?.trackKeys == keys)
    }

    @Test func testAppSettingsRoundTrips() {
        let settings = SyncedSettings(
            eqEnabled: true,
            eqGains: Array(repeating: 1.5, count: EQEngine.bandCount),
            userPresets: [EQPreset(name: "Mine", gains: Array(repeating: 2, count: EQEngine.bandCount), isBuiltIn: false)],
            preferFLAC: true, prefetchDepth: 3, streamOnCellular: false, artworkLookup: true)
        let record = RecordMapping.record(from: settings, zoneID: zoneID)
        #expect(record.recordID.recordName == RecordMapping.appSettingsRecordName)
        let decoded = RecordMapping.syncedSettings(from: record)
        #expect(decoded == settings)
    }
}
