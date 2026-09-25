#if !os(watchOS)
import Foundation
import GRDB
import ParsoAudioNeural
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// The mandatory C06 retrieval fixtures (IMPLEMENT_CLAP_PLAN.md §9/§11 C06),
/// against real pipeline-quantized embedding rows, real analysis attribute
/// rows and the shared `HybridRanker`.
final class SearchServiceTests: XCTestCase {
    private var cacheURL: URL!
    override func setUp() {
        super.setUp()
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-\(UUID().uuidString).bin")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL)
        super.tearDown()
    }

    private let dims = 8

    private func makeService(
        _ queue: DatabaseQueue, queryVector: [Float]? = nil
    ) async -> SearchService {
        let models = ModelManager(resourceProvider: { .unavailable })
        if let queryVector {
            await models.injectModelForTesting(FixedTextModel(dimensions: dims, vector: queryVector))
        }
        let index = VectorIndex(writer: queue, cacheURL: cacheURL)
        return SearchService(writer: queue, index: index, models: models)
    }

    private func unit(_ v: [Float]) -> [Float] { SemanticPooling.l2Normalized(v) }

    // MARK: - Filter-only / browse

    func testFilterOnlyWorksWithNoModelsAndNoEmbeddings() async throws {
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            for (title, bpm) in [("beta", 122.0), ("alpha", 124.0), ("gamma", 90.0)] {
                let t = try SearchFixture.seedTrack(db, sourceId: s, title: title, sortKey: title)
                let a = try SearchFixture.seedAsset(db, trackId: t)
                try SearchFixture.seedAnalysis(db, trackId: t, assetId: a, bpm: bpm)
            }
        }
        let service = await makeService(queue)
        let response = await service.search(
            DiscoverySearchQuery(text: "", bpmMin: 120, bpmMax: 130))

        XCTAssertEqual(response.mode, .filterOnly)
        XCTAssertEqual(response.state, .ready)
        XCTAssertEqual(response.results.map(\.track.track.title), ["alpha", "beta"])
        XCTAssertNil(response.results.first?.similarity)
        XCTAssertNil(response.results.first?.finalScore)
    }

    func testEmptyTextNoFiltersIsMetadataBrowseNotError() async throws {
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            _ = try SearchFixture.seedTrack(db, sourceId: s, title: "z", sortKey: "z")
            _ = try SearchFixture.seedTrack(db, sourceId: s, title: "a", sortKey: "a")
        }
        let service = await makeService(queue)
        let response = await service.search(DiscoverySearchQuery(text: ""))
        XCTAssertEqual(response.mode, .metadataBrowse)
        XCTAssertEqual(response.state, .ready)
        XCTAssertEqual(response.results.map(\.track.track.title), ["a", "z"])
    }

    // MARK: - Empty index vs no matches vs empty library

    func testEmptyLibraryDistinctFromZeroIndexedAndNoMatches() async throws {
        let empty = try SearchFixture.makeQueue()
        let s1 = await makeService(empty, queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))
        let r1 = await s1.search(DiscoverySearchQuery(text: "anything"))
        XCTAssertEqual(r1.state, .emptyLibrary)

        let unindexed = try SearchFixture.makeQueue()
        try await unindexed.write { db in
            let s = try SearchFixture.seedSource(db)
            _ = try SearchFixture.seedTrack(db, sourceId: s, title: "t")
        }
        let s2 = await makeService(unindexed, queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))
        let r2 = await s2.search(DiscoverySearchQuery(text: "anything"))
        XCTAssertEqual(r2.state, .zeroIndexed)

        let indexed = try SearchFixture.makeQueue()
        try await indexed.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "t")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [1, 0, 0, 0, 0, 0, 0, 0])
            try SearchFixture.seedAnalysis(db, trackId: t, assetId: a, bpm: 100)
        }
        let s3 = await makeService(indexed, queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))
        let r3 = await s3.search(DiscoverySearchQuery(text: "x", bpmMin: 160, bpmMax: 170))
        XCTAssertEqual(r3.state, .noMatches)
    }

    // MARK: - Out-of-scope exclusion

    func testOutOfScopeNearestMatchesExcluded() async throws {
        let queue = try SearchFixture.makeQueue()
        let (sourceA, _): (Int64, Int64) = try await queue.write { db in
            let sa = try SearchFixture.seedSource(db, title: "A")
            let sb = try SearchFixture.seedSource(db, title: "B")
            let tb = try SearchFixture.seedTrack(db, sourceId: sb, title: "b-near")
            let ab = try SearchFixture.seedAsset(db, trackId: tb)
            try SearchFixture.seedEmbedding(db, trackId: tb, assetId: ab, vector: [1, 0, 0, 0, 0, 0, 0, 0])
            let ta = try SearchFixture.seedTrack(db, sourceId: sa, title: "a-far")
            let aa = try SearchFixture.seedAsset(db, trackId: ta)
            try SearchFixture.seedEmbedding(db, trackId: ta, assetId: aa, vector: [0.3, 0.95, 0, 0, 0, 0, 0, 0])
            return (sa, sb)
        }
        let service = await makeService(queue, queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))
        let response = await service.search(
            DiscoverySearchQuery(text: "x", sourceIDs: [sourceA]))
        XCTAssertEqual(response.results.map(\.track.track.title), ["a-far"])
    }

    // MARK: - Reference exclusion + hybrid winner below a semantic shortlist

    func testSimilarExcludesReferenceAndHybridBeatsSemanticShortlist() async throws {
        let queue = try SearchFixture.makeQueue()
        let (refID, highSemID, hybridID): (Int64, Int64, Int64) = try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let rt = try SearchFixture.seedTrack(db, sourceId: s, title: "ref")
            let ra = try SearchFixture.seedAsset(db, trackId: rt)
            try SearchFixture.seedEmbedding(db, trackId: rt, assetId: ra, vector: [1, 0, 0, 0, 0, 0, 0, 0])
            try SearchFixture.seedAnalysis(db, trackId: rt, assetId: ra, bpm: 125, key: "8A", energy: 5)

            let ht = try SearchFixture.seedTrack(db, sourceId: s, title: "highsem")
            let ha = try SearchFixture.seedAsset(db, trackId: ht)
            try SearchFixture.seedEmbedding(db, trackId: ht, assetId: ha, vector: [0.95, 0.31, 0, 0, 0, 0, 0, 0])
            try SearchFixture.seedAnalysis(db, trackId: ht, assetId: ha, bpm: 90, key: "2B", energy: 1)

            let yt = try SearchFixture.seedTrack(db, sourceId: s, title: "hybrid")
            let ya = try SearchFixture.seedAsset(db, trackId: yt)
            try SearchFixture.seedEmbedding(db, trackId: yt, assetId: ya, vector: [0.55, 0.83, 0, 0, 0, 0, 0, 0])
            try SearchFixture.seedAnalysis(db, trackId: yt, assetId: ya, bpm: 125, key: "8A", energy: 5)
            return (rt, ht, yt)
        }
        let service = await makeService(queue)
        let response = await service.search(
            DiscoverySearchQuery(text: ""), referenceTrackID: refID)

        XCTAssertEqual(response.mode, .similar(referenceTrackID: refID))
        XCTAssertFalse(response.results.contains { $0.trackID == refID }, "reference must be excluded")
        XCTAssertEqual(response.results.first?.trackID, hybridID, "hybrid winner should rank first")
        let bySemantic = response.results.sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
        XCTAssertEqual(bySemantic.first?.trackID, highSemID)
    }

    func testMatchingTracksGateUsesCamelotAndRelativeBPMBeforeRanking() async throws {
        let queue = try SearchFixture.makeQueue()
        let referenceID: Int64 = try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let ref = try SearchFixture.seedTrack(db, sourceId: s, title: "reference")
            let refAsset = try SearchFixture.seedAsset(db, trackId: ref)
            try SearchFixture.seedEmbedding(
                db, trackId: ref, assetId: refAsset, vector: [1, 0, 0, 0, 0, 0, 0, 0])
            try SearchFixture.seedAnalysis(db, trackId: ref, assetId: refAsset, bpm: 125, key: "1A")

            let fixtures: [(String, Double, String)] = [
                ("relative-key-match", 125, "1B"),
                ("wrapped-key-match", 135, "12A"),
                ("bpm-outside", 136, "1A"),
                ("key-outside", 125, "2B")
            ]
            for (offset, (title, bpm, key)) in fixtures.enumerated() {
                let track = try SearchFixture.seedTrack(
                    db, sourceId: s, title: title, sortKey: "\(offset)-\(title)")
                let asset = try SearchFixture.seedAsset(db, trackId: track)
                try SearchFixture.seedEmbedding(
                    db, trackId: track, assetId: asset,
                    vector: [0.9, 0.43, 0, 0, 0, 0, 0, 0])
                try SearchFixture.seedAnalysis(db, trackId: track, assetId: asset, bpm: bpm, key: key)
            }
            return ref
        }

        let service = await makeService(queue)
        let response = await service.search(
            DiscoverySearchQuery(text: ""), referenceTrackID: referenceID, matchingTracksOnly: true)

        XCTAssertEqual(response.state, .ready)
        XCTAssertEqual(
            Set(response.results.map(\.track.track.title)),
            ["relative-key-match", "wrapped-key-match"])
        XCTAssertFalse(response.results.contains { $0.trackID == referenceID })
    }

    // MARK: - Filtered match below the old global top-N

    func testFilteredHybridMatchRanksAboveHigherSemanticInRange() async throws {
        let queue = try SearchFixture.makeQueue()
        let winnerID: Int64 = try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            for i in 0..<6 {
                let t = try SearchFixture.seedTrack(db, sourceId: s, title: "decoy\(i)")
                let a = try SearchFixture.seedAsset(db, trackId: t)
                try SearchFixture.seedEmbedding(
                    db, trackId: t, assetId: a, vector: [0.9, 0.44, 0, 0, 0, 0, 0, 0])
                try SearchFixture.seedAnalysis(db, trackId: t, assetId: a, bpm: 129.5)
            }
            let w = try SearchFixture.seedTrack(db, sourceId: s, title: "winner")
            let wa = try SearchFixture.seedAsset(db, trackId: w)
            try SearchFixture.seedEmbedding(
                db, trackId: w, assetId: wa, vector: [0.62, 0.78, 0, 0, 0, 0, 0, 0])
            try SearchFixture.seedAnalysis(db, trackId: w, assetId: wa, bpm: 125)
            return w
        }
        let service = await makeService(queue, queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))
        let response = await service.search(
            DiscoverySearchQuery(text: "bright", bpmMin: 120, bpmMax: 130))

        XCTAssertEqual(response.results.first?.trackID, winnerID)
        let bySemantic = response.results.sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
        XCTAssertNotEqual(bySemantic.first?.trackID, winnerID,
            "winner must not be the top pure-semantic result")
    }

    // MARK: - Signed cosine

    func testSignedCosineSurfacedNotClampedToProbability() async throws {
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let near = try SearchFixture.seedTrack(db, sourceId: s, title: "near")
            let na = try SearchFixture.seedAsset(db, trackId: near)
            try SearchFixture.seedEmbedding(db, trackId: near, assetId: na, vector: [1, 0, 0, 0, 0, 0, 0, 0])
            let opp = try SearchFixture.seedTrack(db, sourceId: s, title: "opposite")
            let oa = try SearchFixture.seedAsset(db, trackId: opp)
            try SearchFixture.seedEmbedding(db, trackId: opp, assetId: oa, vector: [-1, 0, 0, 0, 0, 0, 0, 0])
        }
        let service = await makeService(queue, queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))
        let response = await service.search(DiscoverySearchQuery(text: "x"))
        let opp = response.results.first { $0.track.track.title == "opposite" }
        XCTAssertNotNil(opp)
        XCTAssertLessThan(opp!.similarity ?? 0, 0, "raw negative cosine must be exposed, not clamped")
        XCTAssertEqual(response.results.last?.track.track.title, "opposite", "and it ranks last")
    }

    // MARK: - Deterministic ties

    func testDeterministicTieBreakByTrackIDAscending() async throws {
        let queue = try SearchFixture.makeQueue()
        let ids: [Int64] = try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            var ids: [Int64] = []
            for i in 0..<3 {
                let t = try SearchFixture.seedTrack(db, sourceId: s, title: "tie\(i)")
                let a = try SearchFixture.seedAsset(db, trackId: t)
                try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [1, 1, 0, 0, 0, 0, 0, 0])
                ids.append(t)
            }
            return ids
        }
        let service = await makeService(queue, queryVector: unit([1, 1, 0, 0, 0, 0, 0, 0]))
        let a = await service.search(DiscoverySearchQuery(text: "x"))
        let b = await service.search(DiscoverySearchQuery(text: "x"))
        XCTAssertEqual(a.results.map(\.trackID), ids.sorted())
        XCTAssertEqual(a.results.map(\.trackID), b.results.map(\.trackID))
    }

    // MARK: - Stale index generation

    func testStaleIndexGenerationRefreshedBetweenQueries() async throws {
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "first")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [1, 0, 0, 0, 0, 0, 0, 0])
        }
        let service = await makeService(queue, queryVector: unit([0, 1, 0, 0, 0, 0, 0, 0]))
        let g1 = (await service.search(DiscoverySearchQuery(text: "x"))).indexGeneration

        try await queue.write { db in
            let s = try Int64.fetchOne(db, sql: "SELECT id FROM source LIMIT 1")!
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "second")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [0, 1, 0, 0, 0, 0, 0, 0])
        }
        let r2 = await service.search(DiscoverySearchQuery(text: "x"))
        XCTAssertGreaterThan(r2.indexGeneration ?? 0, g1 ?? 0)
        XCTAssertTrue(r2.results.contains { $0.track.track.title == "second" })
    }

    // MARK: - Source / track deletion invalidates results

    func testDeletedTrackDisappearsFromResults() async throws {
        let queue = try SearchFixture.makeQueue()
        let deletedID: Int64 = try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            var first: Int64 = 0
            for i in 0..<3 {
                let t = try SearchFixture.seedTrack(db, sourceId: s, title: "t\(i)")
                let a = try SearchFixture.seedAsset(db, trackId: t)
                try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [1, 0, 0, 0, 0, 0, 0, 0])
                if i == 0 { first = t }
            }
            return first
        }
        let service = await makeService(queue, queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))
        _ = await service.search(DiscoverySearchQuery(text: "x"))
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [deletedID])
        }
        let response = await service.search(DiscoverySearchQuery(text: "x"))
        XCTAssertEqual(response.results.count, 2)
        XCTAssertFalse(response.results.contains { $0.trackID == deletedID })
    }

    /// C06 fixture, previously PARTIAL (session 9): a track deleted *during*
    /// one in-flight scan — not merely between two queries. The scan-block
    /// hook deletes a track while `scanAndRank` is genuinely iterating the
    /// snapshot; the result set must stay consistent (deleted id absent, no
    /// crash) and the engine must revalidate against a fresh snapshot.
    func testTrackDeletedMidScanStaysConsistent() async throws {
        let queue = try SearchFixture.makeQueue()
        let d = 8
        let deletedID: Int64 = try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            var target: Int64 = 0
            for i in 0..<300 {
                let t = try SearchFixture.seedTrack(db, sourceId: s, title: "t\(i)")
                let a = try SearchFixture.seedAsset(db, trackId: t)
                var v = [Float](repeating: 0, count: d)
                v[0] = 1
                v[i % d] += Float(i % 5) * 0.01
                try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: v)
                if i == 7 { target = t }
            }
            return target
        }
        let service = await makeService(
            queue, queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))

        let fired = DeleteOnce(queue: queue, trackID: deletedID)
        await service.setScanBlockHookForTesting { await fired.run() }

        let response = await service.search(DiscoverySearchQuery(text: "x"))

        XCTAssertEqual(response.state, .ready)
        XCTAssertFalse(
            response.results.contains { $0.trackID == deletedID },
            "a track deleted mid-scan must not appear in the result set")
        let didRun = await fired.didRun
        XCTAssertTrue(didRun, "the mid-scan hook must have fired")
        // Every returned row still exists.
        let liveIDs: Set<Int64> = try await queue.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT id FROM track"))
        }
        XCTAssertTrue(response.results.allSatisfy { liveIDs.contains($0.trackID) })
    }

    // MARK: - Similar-track: missing / stale reference embedding

    func testSimilarWithMissingReferenceEmbeddingOffersAnalyze() async throws {
        let queue = try SearchFixture.makeQueue()
        let refID: Int64 = try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let ref = try SearchFixture.seedTrack(db, sourceId: s, title: "ref")
            let other = try SearchFixture.seedTrack(db, sourceId: s, title: "other")
            let a = try SearchFixture.seedAsset(db, trackId: other)
            try SearchFixture.seedEmbedding(db, trackId: other, assetId: a, vector: [1, 0, 0, 0, 0, 0, 0, 0])
            return ref
        }
        let service = await makeService(queue)
        let response = await service.search(
            DiscoverySearchQuery(text: ""), referenceTrackID: refID)
        XCTAssertEqual(response.state, .unindexedReference)
    }

    // MARK: - Semantic mode without a text model

    func testSemanticQueryWithoutTextModelReportsModelMissing() async throws {
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "t")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [1, 0, 0, 0, 0, 0, 0, 0])
        }
        let service = await makeService(queue)
        let response = await service.search(DiscoverySearchQuery(text: "warm pads"))
        XCTAssertEqual(response.state, .modelMissing)
    }

    // MARK: - Coverage states

    func testCoverageReportsIndexingInProgress() async throws {
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t1 = try SearchFixture.seedTrack(db, sourceId: s, title: "done")
            let a1 = try SearchFixture.seedAsset(db, trackId: t1)
            try SearchFixture.seedEmbedding(db, trackId: t1, assetId: a1, vector: [1, 0, 0, 0, 0, 0, 0, 0])
            try SearchFixture.seedJob(db, trackId: t1, state: .complete, embedding: .complete)
            let t2 = try SearchFixture.seedTrack(db, sourceId: s, title: "pending")
            try SearchFixture.seedJob(db, trackId: t2, state: .queued)
        }
        let service = await makeService(queue, queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))
        let response = await service.search(DiscoverySearchQuery(text: "x"))
        XCTAssertEqual(response.coverage?.state, .indexingInProgress)
        XCTAssertEqual(response.coverage?.totalInScope, 2)
        XCTAssertEqual(response.coverage?.indexed, 1)
        XCTAssertEqual(response.coverage?.awaitingIndex, 1)
    }

    // MARK: - Cancellation

    func testCancelledSearchReturnsCancelledAndNoResults() async throws {
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "t")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [1, 0, 0, 0, 0, 0, 0, 0])
        }
        let service = await makeService(queue, queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))
        let response = await service.search(
            DiscoverySearchQuery(text: "x"), isCancelled: { true })
        XCTAssertEqual(response.state, .cancelled)
        XCTAssertTrue(response.results.isEmpty)
    }
}
#endif
