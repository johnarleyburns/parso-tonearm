#if !os(watchOS)
import Foundation
import GRDB
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _downloads = 0, _analyses = 0, _wantsProfile: [Bool] = []
    var downloads: Int { lock.withLock { _downloads } }
    var analyses: Int { lock.withLock { _analyses } }
    var wantsProfile: [Bool] { lock.withLock { _wantsProfile } }
    func download() { lock.withLock { _downloads += 1 } }
    func analyze(_ w: Bool) { lock.withLock { _analyses += 1; _wantsProfile.append(w) } }
}

private struct FakeCache: ManagedAudioCaching {
    let calls: Calls
    var error: Error?
    var onDownload: (@Sendable () -> Void)?
    func downloadAndRetain(asset: Asset) async throws -> URL {
        calls.download()
        onDownload?()
        if let error { throw error }
        return URL(fileURLWithPath: "/cache/\(asset.id ?? 0).mp3")
    }
}

private struct FakeAnalyzer: DiscoveryAudioAnalyzing {
    let calls: Calls
    var onAnalyze: (@Sendable () -> Void)?
    func analyze(url: URL, wantsTransitionProfile: Bool) async throws -> DiscoveryAnalysisOutput {
        calls.analyze(wantsTransitionProfile)
        onAnalyze?()
        var v = [Float](repeating: 0, count: 128); v[0] = 1
        return DiscoveryAnalysisOutput(
            embedding: v, bpm: 120, key: "8A", energy: 0.5,
            profile: wantsTransitionProfile
                ? TransitionProfile(beatPeriodSeconds: 0.5, beatPhaseSeconds: 0.1, beatConfidence: 0.9,
                                    introEndSeconds: 8, outroStartSeconds: 180,
                                    phraseBoundariesSeconds: [8, 16], loudnessEnvelopeDB: [-20, -18], peak: 0.8)
                : nil)
    }
}

final class FullCacheIndexerTests: XCTestCase {
    private let fp = EmbeddingSpace.current.fingerprint

    private func seed(_ q: DatabaseQueue, kind: AssetKind) throws -> (track: Int64, asset: Int64) {
        try q.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "t")
            var a = Asset(id: nil, trackId: t, kind: kind, bookmark: nil, relPath: kind == .remote ? nil : "x.wav",
                          remoteURL: kind == .remote ? "https://example.invalid/a.mp3" : nil,
                          altRemoteURL: nil, sizeBytes: 1, unsupportedReason: nil)
            try a.insert(db)
            return (t, a.id!)
        }
    }

    private func runner(
        _ q: DatabaseQueue, calls: Calls, cache: FakeCache? = nil, analyzer: FakeAnalyzer? = nil,
        network: DiscoveryNetworkClass = .wifi, wifiOnly: Bool = true
    ) -> IntentIndexRunner {
        IntentIndexRunner(
            writer: q, analyzer: analyzer ?? FakeAnalyzer(calls: calls), cache: cache ?? FakeCache(calls: calls),
            resolveLocal: { _ in URL(fileURLWithPath: "/local/x.wav") },
            boundedAnalysisURL: { _ in URL(fileURLWithPath: "/sparse/x.caf") },
            network: { network }, wifiOnly: { wifiOnly })
    }

    private func count(_ q: DatabaseQueue, _ table: String) throws -> Int {
        try q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    func testLocalIndexesInPlaceWithProfileAndNoCacheDownload() async throws {
        let q = try SearchFixture.makeQueue(); let calls = Calls()
        let (t, a) = try seed(q, kind: .localRef)
        try await runner(q, calls: calls).run(intent: .localFile, trackId: t, assetId: a)
        XCTAssertEqual(calls.downloads, 0)
        XCTAssertEqual(calls.wantsProfile, [true])
        XCTAssertEqual(try count(q, "discovery_embedding"), 1)
        XCTAssertEqual(try count(q, "discovery_transition_profile"), 1)
        let dims = try await q.read { try Int.fetchOne($0, sql: "SELECT dimensions FROM discovery_embedding") }
        XCTAssertEqual(dims, 128)
    }

    func testRemoteSparseNeverDownloadsAndWritesNoProfile() async throws {
        let q = try SearchFixture.makeQueue(); let calls = Calls()
        let (t, a) = try seed(q, kind: .remote)
        try await runner(q, calls: calls).run(intent: .remoteSparseEmbedding, trackId: t, assetId: a)
        XCTAssertEqual(calls.downloads, 0)
        XCTAssertEqual(calls.wantsProfile, [false])
        XCTAssertEqual(try count(q, "discovery_embedding"), 1)
        XCTAssertEqual(try count(q, "discovery_transition_profile"), 0)
    }

    func testIntentMismatchIsRejectedWithoutDownload() async throws {
        let q = try SearchFixture.makeQueue(); let calls = Calls()
        let (t, a) = try seed(q, kind: .localRef)
        do {
            try await runner(q, calls: calls).run(intent: .remoteFullCacheAndProfile, trackId: t, assetId: a)
            XCTFail("expected rejection")
        } catch { XCTAssertEqual(error as? DiscoveryIndexError, .wrongIntentForAsset) }
        XCTAssertEqual(calls.downloads, 0)
    }

    func testRemoteFullCacheDownloadsOnceAndWritesProfile() async throws {
        let q = try SearchFixture.makeQueue(); let calls = Calls()
        let (t, a) = try seed(q, kind: .remote)
        try await runner(q, calls: calls).run(intent: .remoteFullCacheAndProfile, trackId: t, assetId: a)
        XCTAssertEqual(calls.downloads, 1)
        XCTAssertEqual(try count(q, "discovery_transition_profile"), 1)
        XCTAssertNotNil(try DiscoveryDerivedStore(writer: q).currentProfile(trackId: t, fingerprint: fp))
    }

    func testWifiOnlyPolicyBlocksDownloadOnCellularAndOffline() async throws {
        let q = try SearchFixture.makeQueue(); let calls = Calls()
        let (t, a) = try seed(q, kind: .remote)
        for net in [DiscoveryNetworkClass.cellular, .offline] {
            do {
                try await runner(q, calls: calls, network: net).run(
                    intent: .remoteFullCacheAndProfile, trackId: t, assetId: a)
                XCTFail("expected block")
            } catch { XCTAssertEqual(error as? DiscoveryIndexError, .networkPolicyBlocked) }
        }
        XCTAssertEqual(calls.downloads, 0)
        // Wi-Fi-only off permits cellular.
        try await runner(q, calls: calls, network: .cellular, wifiOnly: false).run(
            intent: .remoteFullCacheAndProfile, trackId: t, assetId: a)
        XCTAssertEqual(calls.downloads, 1)
    }

    struct DiskFull: Error {}

    func testDownloadFailureAndCancellationWriteNothing() async throws {
        let q = try SearchFixture.makeQueue(); let calls = Calls()
        let (t, a) = try seed(q, kind: .remote)
        do {
            try await runner(q, calls: calls, cache: FakeCache(calls: calls, error: DiskFull())).run(
                intent: .remoteFullCacheAndProfile, trackId: t, assetId: a)
            XCTFail("expected failure")
        } catch { XCTAssertTrue(error is DiskFull) }
        XCTAssertEqual(calls.analyses, 0)

        // Cancel during analysis: nothing is committed.
        let cancelling = runner(
            q, calls: calls,
            analyzer: FakeAnalyzer(calls: calls, onAnalyze: { withUnsafeCurrentTask { $0?.cancel() } }))
        let task = Task { try await cancelling.run(intent: .localFile, trackId: t, assetId: a) }
        _ = await task.result
        for table in ["discovery_embedding", "discovery_track_analysis", "discovery_transition_profile"] {
            XCTAssertEqual(try count(q, table), 0, table)
        }
    }

    func testRevisionChangeMidJobDoesNotCommitOldOutput() async throws {
        let q = try SearchFixture.makeQueue(); let calls = Calls()
        let (t, a) = try seed(q, kind: .remote)
        let bump = FakeCache(calls: calls, onDownload: {
            try? q.write { db in
                try db.execute(sql: """
                    INSERT OR REPLACE INTO discovery_asset_state (assetId, contentRevision, lastValidatedAt)
                    VALUES (?, 2, CURRENT_TIMESTAMP)
                    """, arguments: [a])
            }
        })
        do {
            try await runner(q, calls: calls, cache: bump).run(
                intent: .remoteFullCacheAndProfile, trackId: t, assetId: a)
            XCTFail("expected stale")
        } catch { XCTAssertEqual(error as? DiscoveryIndexError, .staleAssetRevision) }
        XCTAssertEqual(try count(q, "discovery_embedding"), 0)
        XCTAssertEqual(try count(q, "discovery_transition_profile"), 0)
    }

    func testFingerprintMismatchIsNotCommitted() throws {
        let q = try SearchFixture.makeQueue()
        let (t, a) = try seed(q, kind: .localRef)
        var v = [Float](repeating: 0, count: 128); v[0] = 1
        XCTAssertThrowsError(try DiscoveryDerivedStore(writer: q).persistIfCurrent(
            DiscoveryAnalysisOutput(embedding: v), trackId: t, assetId: a, expectedRevision: 1,
            expectedFingerprint: "other-space")) {
            XCTAssertEqual($0 as? DiscoveryIndexError, .staleEmbeddingSpace)
        }
        XCTAssertEqual(try count(q, "discovery_embedding"), 0)
    }

    func testSourceRevisionChangeMakesDerivedStaleAndSchedulesWithoutDeletingTrack() async throws {
        let q = try SearchFixture.makeQueue(); let calls = Calls()
        let (t, a) = try seed(q, kind: .remote)
        try await runner(q, calls: calls).run(intent: .remoteFullCacheAndProfile, trackId: t, assetId: a)
        let store = DiscoveryDerivedStore(writer: q)
        XCTAssertEqual(try store.staleTrackIds(), [])
        try await q.write { db in
            try db.execute(sql: "DELETE FROM discovery_change")
            try db.execute(sql: "UPDATE asset SET remoteURL = 'https://example.invalid/new.mp3' WHERE id = ?", arguments: [a])
            try db.execute(sql: """
                INSERT OR REPLACE INTO discovery_asset_state (assetId, contentRevision, lastValidatedAt)
                VALUES (?, 2, CURRENT_TIMESTAMP)
                """, arguments: [a])
        }
        XCTAssertEqual(try store.staleTrackIds(), [t])
        XCTAssertNil(try store.currentProfile(trackId: t, fingerprint: fp))
        XCTAssertEqual(try count(q, "track"), 1)
        let kinds = try await q.read { try String.fetchAll($0, sql: "SELECT kind FROM discovery_change") }
        XCTAssertTrue(kinds.contains("assetContentReplaced"), "recompute is scheduled via the outbox")
        // Recompute replaces the old rows with revision 2.
        try await runner(q, calls: calls).run(intent: .remoteFullCacheAndProfile, trackId: t, assetId: a)
        XCTAssertEqual(try store.staleTrackIds(), [])
        XCTAssertNotNil(try store.currentProfile(trackId: t, fingerprint: fp))
        XCTAssertEqual(try count(q, "discovery_transition_profile"), 1)
    }

    func testEvictionKeepsDerivedRowsAndExplicitRemoveIsPerTrack() async throws {
        let q = try SearchFixture.makeQueue(); let calls = Calls()
        let (t1, a1) = try seed(q, kind: .remote)
        let (t2, a2) = try seed(q, kind: .remote)
        let r = runner(q, calls: calls)
        try await r.run(intent: .remoteFullCacheAndProfile, trackId: t1, assetId: a1)
        try await r.run(intent: .remoteFullCacheAndProfile, trackId: t2, assetId: a2)
        // Eviction only removes bytes: AudioCache never writes these tables, so nothing changes.
        XCTAssertEqual(try count(q, "discovery_transition_profile"), 2)
        XCTAssertEqual(try count(q, "asset"), 2)

        try DiscoveryDerivedStore(writer: q).removeDerived(trackId: t1)
        XCTAssertEqual(try count(q, "discovery_transition_profile"), 1)
        XCTAssertEqual(try count(q, "discovery_embedding"), 1)
        XCTAssertEqual(try count(q, "discovery_track_analysis"), 1)
        XCTAssertEqual(try count(q, "track"), 2)
        XCTAssertEqual(try count(q, "asset"), 2)
        let left = try await q.read { try Int64.fetchOne($0, sql: "SELECT trackId FROM discovery_transition_profile") }
        XCTAssertEqual(left, t2)
    }

    func testProfileForeignKeysCascadeOnlyFromTrackAndAsset() throws {
        let q = try SearchFixture.makeQueue()
        let fks = try q.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_list(discovery_transition_profile)") }
        XCTAssertEqual(Set(fks.map { $0["table"] as String }), ["track", "asset"])
    }

    func testProfileValidationRejectsBadPayload() {
        XCTAssertThrowsError(try TransitionProfile(beatPeriodSeconds: .nan).validate())
        XCTAssertThrowsError(try TransitionProfile(beatConfidence: 2).validate())
        XCTAssertThrowsError(try TransitionProfile(introEndSeconds: 9, outroStartSeconds: 3).validate())
        XCTAssertNoThrow(try TransitionProfile().validate())
    }
}
#endif
