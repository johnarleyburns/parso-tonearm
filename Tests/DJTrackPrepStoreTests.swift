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

    func testMarkingsAndGridRoundTripAndLegacyImport() async throws {
        let (store, trackID) = try await makeStoreWithTrack()
        let hotLoop = DJHotLoop(position: 20, loopIn: 18, loopOut: 22, color: 4)
        let markings = DJMarkings(hotCues: [1: 2.5], hotCueColors: [1: 0], hotLoops: [8: hotLoop], cuePointSeconds: 1.25,
                                  loopInSeconds: 8, loopOutSeconds: 12)
        try await store.saveDJMarkings(markings, trackId: trackID, at: Date(timeIntervalSince1970: 10))
        try await store.saveDJGrid(bpmOverride: 124, firstBeatOverride: 0.25, keyShiftSemitones: -2,
                                   trackId: trackID, at: Date(timeIntervalSince1970: 11))
        let savedPrep = try await store.djTrackPrep(trackId: trackID)
        let saved = try XCTUnwrap(savedPrep)
        XCTAssertEqual(saved.markings, markings)
        XCTAssertEqual(saved.markings.hotLoops[8], hotLoop)
        XCTAssertEqual(saved.bpmOverride, 124)
        XCTAssertEqual(saved.firstBeatOverride, 0.25)
        XCTAssertEqual(saved.keyShiftSemitones, -2)

        let source = try await store.insertSource(Source(id: nil, kind: .local, iaIdentifier: nil,
                                                         originalURL: nil, title: "DJ 2", addedAt: Date(),
                                                         lastResolvedAt: nil, followUpdates: false,
                                                         licenseText: nil, memberCapHit: false,
                                                         localIsFolder: false, artworkTrackId: nil))
        let sourceID = try XCTUnwrap(source.id)
        let second = try await store.insertTrack(Track(id: nil, albumId: nil, sourceId: sourceID,
                                                       title: "Legacy", trackNo: 1, discNo: nil,
                                                       durationSec: 120, codec: "wav", sampleRate: 48_000,
                                                       bitDepthOrBitrate: nil, sortKey: "legacy"))
        let legacyTrackID = try XCTUnwrap(second.id)
        let legacyKey = "dj.hotCues.v1.\(legacyTrackID)"
        UserDefaults.standard.set(["2": 4.0], forKey: legacyKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }
        let legacyPrep = try await store.djTrackPrep(trackId: legacyTrackID)
        let legacy = try XCTUnwrap(legacyPrep)
        XCTAssertEqual(legacy.markings.hotCues[2], 4.0)
        XCTAssertNil(UserDefaults.standard.object(forKey: legacyKey))
    }

    func testAnalysisRoundTripAndClear() async throws {
        let (store, trackID) = try await makeStoreWithTrack()
        let payload = Data([1, 2, 3])
        try await store.saveDJAnalysis(payload, meta: ("test", 1, 48_000, 123, 128, "8B"), trackId: trackID)
        let saved = try await store.djTrackPrep(trackId: trackID)
        XCTAssertEqual(saved?.analysisPayload, payload)
        try await store.clearDJAnalysis(trackId: trackID)
        let clearedPrep = try await store.djTrackPrep(trackId: trackID)
        let cleared = try XCTUnwrap(clearedPrep)
        XCTAssertNil(cleared.analysisPayload)
        XCTAssertNil(cleared.analysisAlgorithm)
    }

    func testLoopCheckRejectsHalfSetAndReversedRows() async throws {
        let (store, trackID) = try await makeStoreWithTrack()
        do {
            try await store.dbQueue.write { db in
                var row = DJTrackPrep(trackId: trackID, loopInSeconds: 9)
                try row.insert(db)
            }
            XCTFail("a half-set loop must be rejected")
        } catch { }
        do {
            try await store.dbQueue.write { db in
                var row = DJTrackPrep(trackId: trackID, loopInSeconds: 12, loopOutSeconds: 11)
                try row.insert(db)
            }
            XCTFail("a reversed loop must be rejected")
        } catch { }
    }
}
