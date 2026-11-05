import XCTest
import GRDB
@testable import TonearmCore

@MainActor
final class DJTrackPrepStoreTests: XCTestCase {
    private func makeStoreWithTrack() async throws -> (LibraryStore, Int64) {
        let store = try LibraryStore(inMemory: true)
        let source = try await store.insertSource(Source(id: nil, kind: .local, iaIdentifier: nil,
                                                         originalURL: nil, title: "DJ", addedAt: Date(),
                                                         lastResolvedAt: nil, followUpdates: false,
                                                         licenseText: nil, memberCapHit: false,
                                                         localIsFolder: false, artworkTrackId: nil))
        let sourceID = try XCTUnwrap(source.id)
        let track = try await store.insertTrack(Track(id: nil, albumId: nil, sourceId: sourceID,
                                                      title: "Prepared", trackNo: 1, discNo: nil,
                                                      durationSec: 180, codec: "wav", sampleRate: 48_000,
                                                      bitDepthOrBitrate: nil, sortKey: "prepared"))
        return (store, try XCTUnwrap(track.id))
    }

    /// `saveDJMarkings`/`saveDJAnalysis`/`saveDJGrid`/`djTrackPrep(trackId:)` (hot cues, loops,
    /// the analysis-payload blob, and its legacy-`UserDefaults` import) were removed as dead
    /// code — the DJ console that wrote them is gone, and `djLoadTrackInfo` (the only real
    /// reader of this table) only ever read `bpm`/`camelotKey`/`bpmOverride`. See
    /// `testLoadBrowserMetadataUsesDJPrepAsFallback` below for that fallback, constructed
    /// directly against the trimmed `DJTrackPrep` row shape instead.
    func testLoadBrowserMetadataUsesDJPrepAsFallback() async throws {
        let (store, trackID) = try await makeStoreWithTrack()
        try await store.dbQueue.write { db in
            var prep = DJTrackPrep(trackId: trackID, bpm: 126, camelotKey: "8A")
            try prep.insert(db)
        }

        let info = try await store.djLoadTrackInfo(trackIds: [trackID])[trackID]
        XCTAssertEqual(info?.bpm, 126)
        XCTAssertEqual(info?.camelotKey, "8A")
    }

    /// A legacy `DJTrackPrep` CloudKit record from an old app version carries fields this app no
    /// longer stores at all (hot cues, loops, the analysis-payload blob) — `applyIncomingDJTrackPrep`
    /// must apply the fields that survive (bpm/camelotKey/bpmOverride) without erroring on the rest.
    func testApplyIncomingDJTrackPrepAcceptsALegacyEnvelopeAndAppliesOnlyKeptFields() async throws {
        let (store, trackID) = try await makeStoreWithTrack()
        let syncID = try await store.dbQueue.write { db -> String in
            let sync = UUID().uuidString
            try db.execute(sql: "UPDATE track SET syncID = ? WHERE id = ?", arguments: [sync, trackID])
            return sync
        }

        let incoming = DJTrackPrep(trackId: 0, bpm: 126, camelotKey: "8A",
                                   analysisUpdatedAt: Date(timeIntervalSince1970: 100),
                                   syncID: "PREP-REMOTE-1", bpmOverride: 130)
        let envelope = DJTrackPrepEnvelope(prep: incoming, trackSyncID: syncID, trackKeys: [])
        let applied = try await store.applyIncomingDJTrackPrep(envelope)
        XCTAssertEqual(applied, 1)

        let row = try await store.dbQueue.read { db in try DJTrackPrep.fetchOne(db, key: trackID) }
        XCTAssertEqual(row?.bpm, 126)
        XCTAssertEqual(row?.camelotKey, "8A")
        XCTAssertEqual(row?.bpmOverride, 130)
        XCTAssertEqual(row?.syncID, "PREP-REMOTE-1")

        // An older incoming update must not clobber a newer local one.
        let stale = DJTrackPrep(trackId: 0, bpm: 90, camelotKey: "1A",
                                analysisUpdatedAt: Date(timeIntervalSince1970: 50),
                                syncID: "PREP-REMOTE-1", bpmOverride: nil)
        let staleEnvelope = DJTrackPrepEnvelope(prep: stale, trackSyncID: syncID, trackKeys: [])
        _ = try await store.applyIncomingDJTrackPrep(staleEnvelope)
        let unchanged = try await store.dbQueue.read { db in try DJTrackPrep.fetchOne(db, key: trackID) }
        XCTAssertEqual(unchanged?.bpm, 126, "an older update must lose against the already-applied newer one")
    }

    func testLoadBrowserMetadataPrefersCurrentDiscoveryAnalysisAndOverride() async throws {
        let (store, trackID) = try await makeStoreWithTrack()
        let asset = try await store.insertAsset(Asset(
            id: nil, trackId: trackID, kind: .localRef, bookmark: nil,
            relPath: "prepared.wav", remoteURL: nil, altRemoteURL: nil,
            sizeBytes: 1, unsupportedReason: nil))
        let assetID = try XCTUnwrap(asset.id)
        try await store.dbQueue.write { db in
            var analysis = DiscoveryTrackAnalysis(
                trackId: trackID, assetId: assetID, assetRevision: 1,
                analysisVersion: 2, bpm: 128, key: "8B")
            try analysis.insert(db)
            var prep = DJTrackPrep(trackId: trackID, bpm: 124, camelotKey: "7A", bpmOverride: 130)
            try prep.insert(db)
        }

        let info = try await store.djLoadTrackInfo(trackIds: [trackID])[trackID]
        XCTAssertEqual(info?.bpm, 130)
        XCTAssertEqual(info?.camelotKey, "8B")
    }

}
