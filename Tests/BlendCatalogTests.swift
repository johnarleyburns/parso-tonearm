import XCTest
import GRDB
@testable import TonearmCore

final class BlendCatalogTests: XCTestCase {
    private func facts(_ id: String, bpm: Double = 100) -> StarterTrackFacts {
        StarterTrackFacts(id: id, durationSeconds: 240, bpm: bpm, beatPeriod: 60 / bpm, beatPhase: 0.2, rmsDB: -12)
    }

    private func traits(_ key: String, genre: String = "Electronic", sub: String? = "Synthwave") -> BlendTraits {
        BlendTraits(genre: genre, subgenre: sub, camelotKey: key)
    }

    func testCamelotAndGenreAdmissionRules() {
        XCTAssertTrue(BlendTraits.camelotCompatible("8A", "8A"))
        XCTAssertTrue(BlendTraits.camelotCompatible("8A", "9A"))
        XCTAssertTrue(BlendTraits.camelotCompatible("12A", "1A"))
        XCTAssertTrue(BlendTraits.camelotCompatible("8A", "8B"))
        XCTAssertFalse(BlendTraits.camelotCompatible("8A", "9B"))
        XCTAssertFalse(BlendTraits.camelotCompatible("8A", "10A"))
        XCTAssertFalse(BlendTraits.camelotCompatible("8A", "13A"))
        XCTAssertFalse(BlendTraits.camelotCompatible("8A", ""))
        let base = traits("8A")
        XCTAssertTrue(base.isCompatible(with: traits("9A")))
        XCTAssertTrue(base.isCompatible(with: traits("8A", sub: nil)), "one side without a subgenre falls back to genre")
        XCTAssertFalse(base.isCompatible(with: traits("8A", sub: "Progressive House")))
        XCTAssertFalse(base.isCompatible(with: traits("8A", genre: "Folk")))
        XCTAssertFalse(base.isCompatible(with: traits("3A")))
        XCTAssertFalse(base.isCompatible(with: traits("bogus")))
        XCTAssertTrue(base.sharesSubgenre(with: traits("9A")))
        XCTAssertFalse(base.sharesSubgenre(with: traits("9A", sub: nil)))
    }

    func testTraitsArePersistedAndGateSelection() async throws {
        let store = try LibraryStore(inMemory: true)
        let a = "pack:a", b = "pack:b"
        try await store.registerBlendCatalogTrack(key: a, packTag: "pack")
        try await store.registerBlendCatalogTrack(key: b, packTag: "pack")
        do { try await store.markBlendEligible(key: a, facts: facts("a"), traits: traits("zz")); XCTFail() }
        catch { XCTAssertEqual(error as? BlendCatalogError, .missingFacts(a)) }
        try await store.markBlendEligible(key: a, facts: facts("a"), traits: traits("8a"),
                                          sourceURL: "https://example.test/a.m4a", analysisVersion: "v1")
        try await store.markBlendEligible(key: b, facts: facts("b"), traits: traits("3A"))
        let rows = try await store.blendCatalogTracks(atLeast: .blendEligible, packTag: "pack")
        let ra = try XCTUnwrap(rows.first { $0.catalogKey == a }), rb = try XCTUnwrap(rows.first { $0.catalogKey == b })
        XCTAssertEqual(ra.traits, traits("8A"))
        XCTAssertEqual(ra.sourceURL, "https://example.test/a.m4a")
        XCTAssertEqual(ra.analysisVersion, "v1")
        XCTAssertTrue(ra.isSelectable && rb.isSelectable)
        XCTAssertFalse(ra.traits!.isCompatible(with: rb.traits!), "incompatible keys cannot pair")
        // A legacy row (state eligible, no traits) is never selectable.
        var legacy = ra; legacy.genre = nil; legacy.camelotKey = nil
        XCTAssertFalse(legacy.isSelectable)
    }

    func testKeepPlayingCandidateRequiresEligibilityFactsTraitsAndAMirroredLocator() throws {
        let pack = StarterBlendPack.v1
        let real = try XCTUnwrap(StarterBlendCatalog.starterTrackIDs.sorted().first)
        let url = try XCTUnwrap(pack.assetURL(trackID: real)).absoluteString
        func make(_ id: String, state: BlendCatalogState = .blendEligible, source: String?) -> BlendCatalogTrack {
            var row = BlendCatalogTrack(catalogKey: BlendCatalogTrack.key(pack: pack, trackID: id), packTag: pack.releaseTag,
                              state: state, durationSeconds: 240, bpm: 100, beatPeriod: 0.6, beatPhase: 0.2, rmsDB: -12,
                              updatedAt: Date(), genre: "Electronic", subgenre: "Synthwave", camelotKey: "8A",
                              sourceURL: source)
            row.sourceKind = source == nil ? nil : .starterRelease
            return row
        }
        // Seeded and unindexed: never a candidate, even though the catalog gave it a key and a source.
        XCTAssertFalse(make(real, state: .unindexed, source: url).isKeepPlayingCandidate(in: pack))
        let row = make(real, source: url)
        XCTAssertTrue(row.isKeepPlayingCandidate(in: pack))
        XCTAssertEqual(row.resolvedLocator(in: pack), pack.locator(trackID: real))
        // Each missing or invalid fact rejects.
        var bad = row; bad.camelotKey = nil; XCTAssertFalse(bad.isKeepPlayingCandidate(in: pack), "missing key")
        bad = row; bad.camelotKey = "13A"; XCTAssertFalse(bad.isKeepPlayingCandidate(in: pack), "invalid key")
        bad = row; bad.genre = nil; XCTAssertFalse(bad.isKeepPlayingCandidate(in: pack), "missing genre")
        bad = row; bad.beatPeriod = nil; XCTAssertFalse(bad.isKeepPlayingCandidate(in: pack), "incomplete planner facts")
        bad = row; bad.sourceKind = nil; bad.sourceURL = nil; XCTAssertFalse(bad.isKeepPlayingCandidate(in: pack), "no source")
        bad = row; bad.sourceKind = .jamendo; bad.providerTrackID = real
        XCTAssertFalse(bad.isKeepPlayingCandidate(in: pack), "a Jamendo source is never a Starter asset")
        XCTAssertNil(bad.audioLocator(in: pack), "and a Starter ID never resolves through Jamendo")
        bad = row; bad.state = .unindexed; XCTAssertFalse(bad.isKeepPlayingCandidate(in: pack), "not eligible")
        // A synthetic / unmirrored ID has no locator and no Release URL.
        let synthetic = make("999999999", source: "https://github.com/johnarleyburns/parso-tonearm/releases/download/\(pack.releaseTag)/999999999.m4a")
        XCTAssertTrue(synthetic.isSelectable)
        XCTAssertNil(synthetic.resolvedLocator(in: pack))
        XCTAssertFalse(synthetic.isKeepPlayingCandidate(in: pack))
    }

    func testCatalogPlannerRejectsBPMOutsideTolerance() {
        XCTAssertNotNil(CatalogEdgePlanner.plan(blendID: "t", edge: 1, outgoing: facts("a", bpm: 100), incoming: facts("b", bpm: 104)))
        XCTAssertNil(CatalogEdgePlanner.plan(blendID: "t", edge: 1, outgoing: facts("a", bpm: 100), incoming: facts("b", bpm: 130)))
    }

    func testStarterSeedComesFromTheCatalogDatabase() async throws {
        let store = try LibraryStore(inMemory: true)
        let adapter = try StarterCatalogAdapter.bundled()
        let version = try adapter.contentVersion()
        let ids = StarterBlendCatalog.blends.flatMap(\.trackIDs)
        let entries = try adapter.resolve(trackIDs: ids)
        XCTAssertEqual(entries.count, 36)
        let rows = try await store.blendCatalogTracks(atLeast: .unindexed, packTag: StarterBlendPack.v1.releaseTag)
        XCTAssertEqual(rows.count, 36)
        for entry in entries {
            let row = try XCTUnwrap(rows.first { $0.trackID == entry.trackID }, entry.catalogID)
            XCTAssertEqual(row.genre, entry.genre)
            XCTAssertFalse(entry.genre.isEmpty)
            XCTAssertEqual(row.durationSeconds, entry.durationSeconds)
            XCTAssertEqual(row.bpm, entry.bpm)
            XCTAssertTrue(StarterCatalogAdapter.bpmRange.contains(try XCTUnwrap(row.bpm)))
            XCTAssertEqual(row.camelotKey, entry.camelot)
            XCTAssertEqual(row.catalogID, entry.catalogID)
            XCTAssertTrue(entry.catalogID.hasPrefix("jamendo-"))
            XCTAssertNotNil(BlendTraits.parseCamelot(try XCTUnwrap(row.camelotKey)))
            XCTAssertEqual(row.sourceURL, StarterBlendPack.v1.assetURL(trackID: entry.trackID)?.absoluteString)
            XCTAssertEqual(row.analysisVersion, "starter-v4:\(version)")
            // Beat grid and loudness are not in the catalog: never invented, so the row stays unindexed.
            XCTAssertEqual(row.state, .unindexed)
            XCTAssertNil(row.beatPeriod); XCTAssertNil(row.beatPhase); XCTAssertNil(row.rmsDB)
            XCTAssertFalse(row.isSelectable)
        }
    }

    func testStarterSeedIsIdempotentAndRefreshesStaleCatalogFacts() async throws {
        let store = try LibraryStore(inMemory: true)
        let key = BlendCatalogTrack.key(pack: .v1, trackID: StarterBlendCatalog.blends[0].trackIDs[0])
        try await store.dbQueue.write { db in
            var row = try XCTUnwrap(BlendCatalogTrack.fetchOne(db, key: key))
            row.bpm = 1; row.genre = "Stale"; row.camelotKey = "1A"; row.state = .blendEligible
            row.beatPeriod = 0.5; row.beatPhase = 0.1; row.rmsDB = -10
            try row.update(db)
            try LibraryStore.seedStarterCatalog(db)
            try LibraryStore.seedStarterCatalog(db)
        }
        let row = try await store.blendCatalogTrack(key: key)
        let fresh = try StarterCatalogAdapter.bundled().resolve(trackIDs: [StarterBlendCatalog.blends[0].trackIDs[0]])[0]
        XCTAssertEqual(row?.bpm, fresh.bpm)
        XCTAssertEqual(row?.genre, fresh.genre)
        XCTAssertEqual(row?.camelotKey, fresh.camelot)
        XCTAssertEqual(row?.state, .blendEligible, "progress made by indexing is kept")
        XCTAssertEqual(row?.beatPeriod, 0.5)
        let count = try await store.blendCatalogTracks(atLeast: .unindexed, packTag: StarterBlendPack.v1.releaseTag).count
        XCTAssertEqual(count, 36)
    }

    /// Copies the real catalog and applies `mutate`, so failures are exercised against actual data.
    private func mutatedCatalog(_ mutate: (Database) throws -> Void) throws -> StarterCatalogAdapter {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("catalog.sqlite")
        try FileManager.default.copyItem(at: try XCTUnwrap(StarterLibrary.bundledURL), to: copy)
        try DatabaseQueue(path: copy.path).write { try mutate($0) }
        return StarterCatalogAdapter(url: copy)
    }

    func testStarterCatalogAdapterResolvesRealPlaybackMetadataForAllPackTracks() throws {
        let adapter = try StarterCatalogAdapter.bundled()
        let ids = StarterBlendCatalog.blends.flatMap(\.trackIDs)
        let entries = try adapter.resolve(trackIDs: ids)
        XCTAssertEqual(entries.count, 36)
        XCTAssertEqual(entries.map(\.trackID), ids)
        XCTAssertTrue(entries.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertTrue(entries.allSatisfy { !$0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    func testStarterSeedFailsAtomicallyOnABadCatalog() throws {
        let first = StarterBlendCatalog.blends[0].trackIDs[0], last = StarterBlendCatalog.blends[5].trackIDs[5]
        let cases: [(String, (Database) throws -> Void, StarterCatalogError)] = [
            ("absent", { try $0.execute(sql: "DELETE FROM starter_track WHERE id = ?", arguments: ["jamendo-\(last)"]) },
             .missing(["jamendo-\(last)"])),
            ("title", { try $0.execute(sql: "UPDATE starter_track SET title = '  ' WHERE id = ?", arguments: ["jamendo-\(last)"]) },
             .invalid(id: "jamendo-\(last)", reason: "title")),
            ("artist", { try $0.execute(sql: "UPDATE starter_track SET artist = '' WHERE id = ?", arguments: ["jamendo-\(last)"]) },
             .invalid(id: "jamendo-\(last)", reason: "artist")),
            ("bpm", { try $0.execute(sql: "UPDATE starter_track SET bpm = NULL WHERE id = ?", arguments: ["jamendo-\(last)"]) },
             .invalid(id: "jamendo-\(last)", reason: "bpm")),
            ("camelot", { try $0.execute(sql: "UPDATE starter_track SET camelot = '13A' WHERE id = ?", arguments: ["jamendo-\(last)"]) },
             .invalid(id: "jamendo-\(last)", reason: "camelot")),
            ("version", { try $0.execute(sql: "UPDATE starter_meta SET value = '99' WHERE key = 'format_version'") },
             .incompatibleVersion("99"))]
        for (name, mutate, expected) in cases {
            let adapter = try mutatedCatalog(mutate)
            let queue = try DatabaseQueue()
            try queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE blend_catalog_track (catalogKey TEXT PRIMARY KEY, packTag TEXT, state TEXT, durationSeconds REAL,
                        bpm REAL, beatPeriod REAL, beatPhase REAL, rmsDB REAL, updatedAt DATETIME, genre TEXT, subgenre TEXT,
                        camelotKey TEXT, sourceURL TEXT, analysisVersion TEXT, catalogID TEXT,
                        sourceKind TEXT, providerTrackID TEXT, cachedURL TEXT, cachedURLExpiry DATETIME);
                    CREATE TABLE blend_catalog_edge (fromKey TEXT, toKey TEXT, packTag TEXT, planJSON BLOB, PRIMARY KEY (fromKey, toKey));
                    """)
            }
            XCTAssertThrowsError(try queue.write { try LibraryStore.seedStarterCatalog($0, catalog: adapter) }, name) {
                XCTAssertEqual($0 as? StarterCatalogError, expected, name)
            }
            let rows = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM blend_catalog_track") }
            XCTAssertEqual(rows, 0, "\(name): nothing is written, not even the valid ids like \(first)")
        }
    }

    func testStarterSeedRollsBackEverythingWhenAnEdgeWriteFails() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE blend_catalog_track (catalogKey TEXT PRIMARY KEY, packTag TEXT, state TEXT, durationSeconds REAL,
                    bpm REAL, beatPeriod REAL, beatPhase REAL, rmsDB REAL, updatedAt DATETIME, genre TEXT, subgenre TEXT,
                    camelotKey TEXT, sourceURL TEXT, analysisVersion TEXT, catalogID TEXT,
                        sourceKind TEXT, providerTrackID TEXT, cachedURL TEXT, cachedURLExpiry DATETIME);
                CREATE TABLE blend_catalog_edge (fromKey TEXT, toKey TEXT, packTag TEXT, planJSON BLOB, PRIMARY KEY (fromKey, toKey));
                CREATE TRIGGER fail_edge BEFORE INSERT ON blend_catalog_edge BEGIN SELECT RAISE(ABORT, 'injected'); END;
                """)
        }
        XCTAssertThrowsError(try queue.write { try LibraryStore.seedStarterCatalog($0) })
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM blend_catalog_track"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM blend_catalog_edge"), 0)
        }
    }

    func testStarterSeedSourceDoesNotReadRuntimeFactsOrHardCodedTraits() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Data/LibraryStore+BlendCatalog.swift"), encoding: .utf8)
        let body = String(source[source.range(of: "static func seedStarterCatalog")!.lowerBound...].prefix(2500))
        XCTAssertFalse(body.contains("StarterBlendRuntimeData.tracks"))
        XCTAssertTrue(body.contains("StarterCatalogAdapter"))
    }

    func testStarterSeedRejectsADuplicatedTrackID() throws {
        let adapter = try StarterCatalogAdapter.bundled()
        let id = StarterBlendCatalog.blends[0].trackIDs[0]
        XCTAssertThrowsError(try adapter.resolve(trackIDs: [id, id])) {
            XCTAssertEqual($0 as? StarterCatalogError, .duplicated(["jamendo-\(id)"]))
        }
    }

    func testFreshInstallSeedsTheCatalogAndSuppliedPlans() async throws {
        let store = try LibraryStore(inMemory: true)
        let tracks = try await store.blendCatalogTracks(atLeast: .unindexed, packTag: StarterBlendPack.v1.releaseTag)
        XCTAssertEqual(tracks.count, 36)
        for blend in StarterBlendCatalog.blends {
            for plan in blend.edgePlans {
                let stored = try await store.blendCatalogEdgePlan(
                    from: BlendCatalogTrack.key(pack: .v1, trackID: plan.outgoingTrackID),
                    to: BlendCatalogTrack.key(pack: .v1, trackID: plan.incomingTrackID))
                XCTAssertEqual(stored, plan, "\(blend.id) edge \(plan.edge) survives persistence exactly")
            }
        }
    }

    func testLifecycleMovesForwardOneStepAtATime() async throws {
        let store = try LibraryStore(inMemory: true)
        let a = "pack:a", b = "pack:b"
        try await store.registerBlendCatalogTrack(key: a, packTag: "pack")
        try await store.registerBlendCatalogTrack(key: b, packTag: "pack")
        var row = try await store.blendCatalogTrack(key: a)
        XCTAssertEqual(row?.state, .unindexed)
        // Not eligible yet: nothing selects it and no plan may be attached.
        let eligibleBefore = try await store.blendCatalogTracks(atLeast: .blendEligible, packTag: "pack")
        XCTAssertTrue(eligibleBefore.isEmpty)
        let plan = try XCTUnwrap(CatalogEdgePlanner.plan(blendID: "x", edge: 1, outgoing: facts("a"), incoming: facts("b")))
        do { try await store.recordBlendEdgePlan(plan, from: a, to: b, packTag: "pack"); XCTFail("unindexed cannot be planned") }
        catch { XCTAssertEqual(error as? BlendCatalogError, .illegalTransition(from: .unindexed, to: .edgePlanned)) }
        // Facts must be complete and valid.
        var bad = facts("a"); bad = StarterTrackFacts(id: "a", durationSeconds: 0, bpm: 100, beatPeriod: 0.6, beatPhase: 0, rmsDB: -10)
        do { try await store.markBlendEligible(key: a, facts: bad, traits: traits("8A")); XCTFail() }
        catch { XCTAssertEqual(error as? BlendCatalogError, .missingFacts(a)) }

        try await store.markBlendEligible(key: a, facts: facts("a"), traits: traits("8A"))
        try await store.markBlendEligible(key: b, facts: facts("b"), traits: traits("9A"))
        row = try await store.blendCatalogTrack(key: a)
        XCTAssertEqual(row?.state, .blendEligible)
        XCTAssertEqual(row?.facts, facts("a"))
        do { try await store.markBlendEligible(key: a, facts: facts("a"), traits: traits("8A")); XCTFail("no repeat/skip") }
        catch { XCTAssertEqual(error as? BlendCatalogError, .illegalTransition(from: .blendEligible, to: .blendEligible)) }
        let eligible = try await store.blendCatalogTracks(atLeast: .blendEligible, packTag: "pack")
        XCTAssertEqual(eligible.count, 2)

        try await store.recordBlendEdgePlan(plan, from: a, to: b, packTag: "pack")
        for key in [a, b] {
            let state = try await store.blendCatalogTrack(key: key)?.state
            XCTAssertEqual(state, .edgePlanned)
        }
        let stored = try await store.blendCatalogEdgePlan(from: a, to: b)
        XCTAssertEqual(stored, plan)
        do { try await store.markBlendEligible(key: "pack:missing", facts: facts("m"), traits: traits("8A")); XCTFail() }
        catch { XCTAssertEqual(error as? BlendCatalogError, .unknownTrack("pack:missing")) }
    }

    func testStateOrderingAndSteps() {
        XCTAssertTrue(BlendCatalogState.unindexed < .blendEligible)
        XCTAssertTrue(BlendCatalogState.blendEligible < .edgePlanned)
        XCTAssertTrue(BlendCatalogState.unindexed.canAdvance(to: .blendEligible))
        XCTAssertFalse(BlendCatalogState.unindexed.canAdvance(to: .edgePlanned))
        XCTAssertFalse(BlendCatalogState.edgePlanned.canAdvance(to: .blendEligible))
    }

    func testCatalogPlannerUsesOnlyStoredFactsAndRejectsMismatchedPairs() throws {
        let out = facts("a", bpm: 100), near = facts("b", bpm: 104), far = facts("c", bpm: 130)
        let plan = try XCTUnwrap(CatalogEdgePlanner.plan(blendID: "x", edge: 3, outgoing: out, incoming: near))
        XCTAssertEqual(plan.style, .bassSwap)
        XCTAssertEqual(plan.tempo, 100.0 / 104.0, accuracy: 1e-12)
        XCTAssertEqual(plan.overlapBeats, 32)
        let s = try XCTUnwrap(plan.schedule())
        // The incoming's first beat lands on the overlap start, on the outgoing's beat grid.
        XCTAssertEqual(s.incomingStart, near.beatPhase, accuracy: 1e-9)
        let beats = (s.outgoingStart - out.beatPhase) / out.beatPeriod
        XCTAssertEqual(beats, beats.rounded(), accuracy: 1e-6, "starts on the outgoing's beat grid")
        XCTAssertLessThanOrEqual(s.outgoingStart + s.overlapSeconds, out.durationSeconds - CatalogEdgePlanner.tailSeconds + 0.01)
        XCTAssertGreaterThanOrEqual(plan.incomingGain ?? 0, 0.5)
        XCTAssertLessThanOrEqual(plan.incomingGain ?? 0, 1.6)
        XCTAssertNil(CatalogEdgePlanner.plan(blendID: "x", edge: 1, outgoing: out, incoming: far), "beyond ±8% tempo")
        let short = StarterTrackFacts(id: "s", durationSeconds: 30, bpm: 100, beatPeriod: 0.6, beatPhase: 0, rmsDB: -10)
        XCTAssertNil(CatalogEdgePlanner.plan(blendID: "x", edge: 1, outgoing: short, incoming: near), "no room for the overlap")
        XCTAssertNil(CatalogEdgePlanner.plan(blendID: "x", edge: 1, outgoing: out,
                                             incoming: StarterTrackFacts(id: "u", durationSeconds: 240, bpm: 0, beatPeriod: 0, beatPhase: 0, rmsDB: .nan)))
    }

    func testMigrationListIncludesTheCatalog() {
        XCTAssertEqual(Schema.migrationOrder.last, "v38")
    }
}
