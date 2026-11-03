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
        func make(_ id: String, state: BlendCatalogState = .blendEligible, providerTrackID: String?) -> BlendCatalogTrack {
            var row = BlendCatalogTrack(catalogKey: BlendCatalogTrack.jamendoKey(trackID: id),
                              packTag: BlendCatalogTrack.jamendoPackTag,
                              state: state, durationSeconds: 240, bpm: 100, beatPeriod: 0.6, beatPhase: 0.2, rmsDB: -12,
                              updatedAt: Date(), genre: "Electronic", subgenre: "Synthwave", camelotKey: "8A")
            row.sourceKind = providerTrackID == nil ? nil : .jamendo
            row.providerTrackID = providerTrackID
            return row
        }
        // Seeded and unindexed: never a candidate, even with a complete source.
        XCTAssertFalse(make("4242", state: .unindexed, providerTrackID: "4242").isKeepPlayingCandidate())
        let row = make("4242", providerTrackID: "4242")
        XCTAssertTrue(row.isKeepPlayingCandidate())
        XCTAssertEqual(row.keepPlayingLocator(), .jamendo(trackID: "4242", cachedURL: nil, expiry: nil))
        // Each missing or invalid fact rejects.
        var bad = row; bad.camelotKey = nil; XCTAssertFalse(bad.isKeepPlayingCandidate(), "missing key")
        bad = row; bad.camelotKey = "13A"; XCTAssertFalse(bad.isKeepPlayingCandidate(), "invalid key")
        bad = row; bad.genre = nil; XCTAssertFalse(bad.isKeepPlayingCandidate(), "missing genre")
        bad = row; bad.beatPeriod = nil; XCTAssertFalse(bad.isKeepPlayingCandidate(), "incomplete planner facts")
        bad = row; bad.sourceKind = nil; XCTAssertFalse(bad.isKeepPlayingCandidate(), "no source")
        bad = row; bad.providerTrackID = ""; XCTAssertFalse(bad.isKeepPlayingCandidate(), "no provider identity")
        bad = row; bad.providerTrackID = "4243"; XCTAssertFalse(bad.isKeepPlayingCandidate(), "identity must match the row")
        bad = row; bad.state = .unindexed; XCTAssertFalse(bad.isKeepPlayingCandidate(), "not eligible")
        // A legacy row seeded with no providerTrackID falls back to the catalog key's own track ID.
        var legacy = row; legacy.providerTrackID = nil
        XCTAssertEqual(legacy.keepPlayingLocator(), .jamendo(trackID: "4242", cachedURL: nil, expiry: nil))
    }

    func testCatalogPlannerRejectsBPMOutsideTolerance() {
        XCTAssertNotNil(CatalogEdgePlanner.plan(blendID: "t", edge: 1, outgoing: facts("a", bpm: 100), incoming: facts("b", bpm: 104)))
        XCTAssertNil(CatalogEdgePlanner.plan(blendID: "t", edge: 1, outgoing: facts("a", bpm: 100), incoming: facts("b", bpm: 130)))
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
        XCTAssertEqual(Schema.migrationOrder.last, "v40")
    }
}
