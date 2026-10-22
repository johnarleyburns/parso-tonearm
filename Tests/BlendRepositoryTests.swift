import XCTest
@testable import TonearmCore

final class BlendRepositoryTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("blends.json") }
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func row(_ id: Int64, sync: String?, kind: AssetKind = .managedCopy, needsReimport: Bool = false) -> TrackRow {
        TrackRow(track: Track(id: id, albumId: nil, sourceId: 1, title: "T\(id)", trackNo: nil, discNo: nil,
                              durationSec: 100, codec: nil, sampleRate: nil, bitDepthOrBitrate: nil,
                              sortKey: "t\(id)", syncID: sync),
                 album: nil, source: nil,
                 asset: Asset(id: id, trackId: id, kind: kind, bookmark: nil, relPath: "a\(id).mp3",
                              remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil,
                              needsReimport: needsReimport))
    }

    private func queue() -> [TrackRow] { [row(1, sync: "A"), row(2, sync: "B"), row(1, sync: "A")] }

    func testSaveReopenReplayPreservesOrderAndIntent() async throws {
        let plan = MixPlan(steps: [], excluded: [], summary: .init(), request: MixRequest(candidates: []),
                           transitionPlans: [TransitionPlan(fromTrackID: 1, toTrackID: 2, style: .phraseFade)])
        let doc = BlendReplay.document(from: queue(), plan: plan, title: "Mine", origin: .blendLab, now: t0)
        try await BlendRepository(url: url).save(doc)

        let reopened = await BlendRepository(url: url).load()
        XCTAssertEqual(reopened.blends, [doc])
        let saved = try XCTUnwrap(reopened.blends.first)
        XCTAssertEqual(saved.edges.map(\.requestedStyle), ["phraseFade", nil])
        let entries = BlendReplay.resolve(saved, lookup: BlendReplay.lookup(in: queue()))
        XCTAssertEqual(BlendReplay.playableQueue(entries).map(\.track.syncID), ["A", "B", "A"])
    }

    func testCatalogEdgePlanRoundTripsWithTheUniqueOccurrenceEdge() async throws {
        let occurrences = [BlendDocument.Occurrence(source: .init(syncID: "A", title: "A")),
                           BlendDocument.Occurrence(source: .init(syncID: "B", title: "B"))]
        var doc = BlendDocument(title: "Catalog", origin: .starter, now: t0, occurrences: occurrences)
        doc.edges[0].catalogPlan = CatalogEdgePlan(fromCatalogTrackID: "jamendo:A", toCatalogTrackID: "jamendo:B",
                                                   analysisVersion: 1, style: "bass-swap",
                                                   outgoingPhraseSeconds: 64, incomingPhraseSeconds: 16,
                                                   overlapBeats: 64, blendStartSeconds: 40, swapSeconds: 64,
                                                   blendEndSeconds: 88, incomingOffsetSeconds: 0,
                                                   tempo: 1.01, incomingGain: 0.9)
        try await BlendRepository(url: url).save(doc)
        let snapshot = await BlendRepository(url: url).load()
        let restored = try XCTUnwrap(snapshot.blends.first)
        XCTAssertEqual(restored.edges[0].catalogPlan, doc.edges[0].catalogPlan)
        XCTAssertEqual(restored.schemaVersion, BlendDocument.currentSchemaVersion)
    }

    func testDuplicateOccurrencesStayDistinctAndEditsAreIndependent() {
        let doc = BlendReplay.document(from: [row(1, sync: "A"), row(1, sync: "A")], title: "AA", origin: .manualQueue, now: t0)
        XCTAssertEqual(Set(doc.occurrences.map(\.id)).count, 2)
        XCTAssertEqual(doc.edges.count, 1)
        let third = BlendDocument.Occurrence(source: doc.occurrences[0].source)
        let edited = doc.replacingOccurrences([doc.occurrences[0], doc.occurrences[1], third], now: t0)
        XCTAssertEqual(edited.generation, 2)
        XCTAssertEqual(edited.edges[0].id, doc.edges[0].id)
        XCTAssertNotEqual(edited.edges[1].id, edited.edges[0].id)
        XCTAssertEqual(doc.occurrences.count, 2) // prior document untouched
    }

    func testMissingAndUnavailableAreReportedNotSubstituted() {
        let doc = BlendReplay.document(from: [row(1, sync: "A"), row(2, sync: "B"),
                                              row(3, sync: "C", kind: .remote)], title: "x", origin: .starter, now: t0)
        let library = [row(1, sync: "A"), row(2, sync: "B", needsReimport: true)]
        let entries = BlendReplay.resolve(doc, lookup: BlendReplay.lookup(in: library))
        XCTAssertEqual(entries.map(\.status), [.playable, .missingLocalFile, .unavailableRemote])
        XCTAssertEqual(BlendReplay.playableQueue(entries).map(\.id), [1])
    }

    func testSaveIsIdempotentAndConcurrentSafe() async throws {
        let repo = BlendRepository(url: url)
        let doc = BlendReplay.document(from: queue(), title: "x", origin: .manualQueue, now: t0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = try? await repo.save(doc) } }
        }
        var snapshot = await repo.load()
        XCTAssertEqual(snapshot.blends.count, 1)
        try await repo.remove(id: doc.id)
        try await repo.remove(id: doc.id)
        snapshot = await repo.load()
        XCTAssertTrue(snapshot.blends.isEmpty)
    }

    func testRemoveOnlyRemovesTargetAndPersistenceFailureKeepsState() async throws {
        let repo = BlendRepository(url: url)
        let a = BlendReplay.document(from: queue(), title: "a", origin: .manualQueue, now: t0)
        let b = BlendReplay.document(from: queue(), title: "b", origin: .manualQueue, now: t0)
        try await repo.save(a); try await repo.save(b)
        try await repo.remove(id: a.id)
        let remaining = await repo.load().blends
        XCTAssertEqual(remaining.map(\.id), [b.id])

        // Make the write fail: the target path is a directory.
        let bad = BlendRepository(url: dir)
        do { try await bad.save(a); XCTFail("expected failure") } catch {
            XCTAssertTrue(error is BlendRepository.RepositoryError)
        }
        let after = await bad.load().blends
        XCTAssertTrue(after.isEmpty)
    }

    func testMalformedIsQuarantinedAndRecoverable() async throws {
        try Data("not json".utf8).write(to: url)
        let repo = BlendRepository(url: url)
        let snap = await repo.load()
        XCTAssertTrue(snap.blends.isEmpty)
        guard case .malformedQuarantined? = snap.issues.first else { return XCTFail("no issue") }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.contains("malformed") })
        try await repo.save(BlendReplay.document(from: queue(), title: "ok", origin: .manualQueue, now: t0))
        let reloaded = await BlendRepository(url: url).load()
        XCTAssertEqual(reloaded.blends.count, 1)
    }

    func testLegacyMigratesAndNewerSchemaIsReadOnly() async throws {
        let id = UUID()
        try Data(#"{"blends":[{"id":"\#(id.uuidString)","title":"Old","trackSyncIDs":["A","A"]}]}"#.utf8).write(to: url)
        let snap = await BlendRepository(url: url).load()
        XCTAssertEqual(snap.blends.first?.id, id)
        XCTAssertEqual(snap.blends.first?.occurrences.count, 2)
        XCTAssertEqual(snap.issues, [.legacyMigrated(0)])

        let newer = dir.appendingPathComponent("newer.json")
        try Data(#"{"schemaVersion":99,"blends":[]}"#.utf8).write(to: newer)
        let repo = BlendRepository(url: newer)
        let s2 = await repo.load()
        XCTAssertEqual(s2.issues, [.newerSchema(99)])
        do { try await repo.save(BlendReplay.document(from: queue(), title: "n", origin: .manualQueue)); XCTFail() }
        catch { XCTAssertEqual(error as? BlendRepository.RepositoryError, .readOnly) }
    }
}
