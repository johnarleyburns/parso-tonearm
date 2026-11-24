import Foundation
import Testing
import GRDB
@testable import TonearmCore

@MainActor
@Suite struct DJTrackPrepStoreTests {
    private func makeStoreWithTrack() async throws -> (LibraryStore, Int64) {
        let store = try LibraryStore(inMemory: true)
        let source = try await store.insertSource(Source(id: nil, kind: .local, iaIdentifier: nil,
                                                         originalURL: nil, title: "DJ", addedAt: Date(),
                                                         lastResolvedAt: nil, followUpdates: false,
                                                         licenseText: nil, memberCapHit: false,
                                                         localIsFolder: false, artworkTrackId: nil))
        let sourceID = try #require(source.id)
        let track = try await store.insertTrack(Track(id: nil, albumId: nil, sourceId: sourceID,
                                                      title: "Prepared", trackNo: 1, discNo: nil,
                                                      durationSec: 180, codec: "wav", sampleRate: 48_000,
                                                      bitDepthOrBitrate: nil, sortKey: "prepared"))
        return (store, try #require(track.id))
    }

    /// `saveDJMarkings`/`saveDJAnalysis`/`saveDJGrid`/`djTrackPrep(trackId:)` (hot cues, loops,
    /// the analysis-payload blob, and its legacy-`UserDefaults` import) were removed as dead
    /// code — the DJ console that wrote them is gone, and `djLoadTrackInfo` (the only real
    /// reader of this table) only ever read `bpm`/`camelotKey`/`bpmOverride`. See
    /// `testLoadBrowserMetadataUsesDJPrepAsFallback` below for that fallback, constructed
    /// directly against the trimmed `DJTrackPrep` row shape instead.
    @Test func testLoadBrowserMetadataUsesDJPrepAsFallback() async throws {
        let (store, trackID) = try await makeStoreWithTrack()
        try await store.dbQueue.write { db in
            var prep = DJTrackPrep(trackId: trackID, bpm: 126, camelotKey: "8A")
            try prep.insert(db)
        }

        let info = try await store.djLoadTrackInfo(trackIds: [trackID])[trackID]
        #expect(info?.bpm == 126)
        #expect(info?.camelotKey == "8A")
    }

    @Test func testLoadBrowserMetadataPrefersCurrentDiscoveryAnalysisAndOverride() async throws {
        let (store, trackID) = try await makeStoreWithTrack()
        let asset = try await store.insertAsset(Asset(
            id: nil, trackId: trackID, kind: .localRef, bookmark: nil,
            relPath: "prepared.wav", remoteURL: nil, altRemoteURL: nil,
            sizeBytes: 1, unsupportedReason: nil))
        let assetID = try #require(asset.id)
        try await store.dbQueue.write { db in
            var analysis = DiscoveryTrackAnalysis(
                trackId: trackID, assetId: assetID, assetRevision: 1,
                analysisVersion: 2, bpm: 128, key: "8B")
            try analysis.insert(db)
            var prep = DJTrackPrep(trackId: trackID, bpm: 124, camelotKey: "7A", bpmOverride: 130)
            try prep.insert(db)
        }

        let info = try await store.djLoadTrackInfo(trackIds: [trackID])[trackID]
        #expect(info?.bpm == 130)
        #expect(info?.camelotKey == "8B")
    }

}
