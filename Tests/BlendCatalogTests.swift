import XCTest
import GRDB
@testable import TonearmCore

final class BlendCatalogTests: XCTestCase {
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

    /// Regression for the real report "every launch shows a Jamendo track unavailable toast":
    /// v38's backfill once wrote an explicit "" instead of nil for some rows (fixed going
    /// forward, but already-applied installs needed a separate repair, v41, since a migration
    /// never re-runs). Without it, `audioLocator()` correctly rejects "" — so a persisted queue
    /// whose current track was exactly such a row failed to resolve on every single launch.
    func testRepairEmptyProviderTrackIDsClearsThemSoAudioLocatorFallsBackAgain() async throws {
        let store = try LibraryStore(inMemory: true)
        let key = BlendCatalogTrack.jamendoKey(trackID: "9999")
        try await store.upsertJamendoCatalogTrack(trackID: "9999", cachedURL: nil)
        try await store.dbQueue.write { db in
            var row = try XCTUnwrap(BlendCatalogTrack.fetchOne(db, key: key))
            row.sourceKind = .jamendo
            row.providerTrackID = ""
            try row.update(db)
        }
        let before = try await store.dbQueue.read { db in try XCTUnwrap(BlendCatalogTrack.fetchOne(db, key: key)) }
        XCTAssertNil(before.audioLocator(), "unrepaired \"\" is still correctly rejected")

        try await store.dbQueue.write { db in try LibraryStore.repairEmptyProviderTrackIDs(db) }

        let after = try await store.dbQueue.read { db in try XCTUnwrap(BlendCatalogTrack.fetchOne(db, key: key)) }
        XCTAssertNil(after.providerTrackID, "repaired back to nil, not re-derived here")
        XCTAssertEqual(after.audioLocator(), .jamendo(trackID: "9999", cachedURL: nil, expiry: nil),
                      "nil now falls back to the catalog key's own track ID again")

        // A row with a real, non-empty providerTrackID must be left alone.
        let untouchedKey = BlendCatalogTrack.jamendoKey(trackID: "1111")
        try await store.upsertJamendoCatalogTrack(trackID: "1111", cachedURL: nil)
        try await store.dbQueue.write { db in
            var row = try XCTUnwrap(BlendCatalogTrack.fetchOne(db, key: untouchedKey))
            row.sourceKind = .jamendo
            row.providerTrackID = "1111"
            try row.update(db)
        }
        try await store.dbQueue.write { db in try LibraryStore.repairEmptyProviderTrackIDs(db) }
        let untouched = try await store.dbQueue.read { db in try XCTUnwrap(BlendCatalogTrack.fetchOne(db, key: untouchedKey)) }
        XCTAssertEqual(untouched.providerTrackID, "1111")
    }

    /// `backfillCatalogSources` (v38) itself must never write the bug `testRepairEmptyProviderTrackIDs...`
    /// repairs — covers the specific input that produced it: a `catalogID` that survives the
    /// "jamendo-" strip as empty (a bare "jamendo-" with nothing after it).
    func testBackfillNeverWritesAnEmptyProviderTrackID() async throws {
        let store = try LibraryStore(inMemory: true)
        let key = BlendCatalogTrack.jamendoKey(trackID: "7777")
        try await store.upsertJamendoCatalogTrack(trackID: "7777", cachedURL: nil)
        try await store.dbQueue.write { db in
            var row = try XCTUnwrap(BlendCatalogTrack.fetchOne(db, key: key))
            row.sourceKind = nil          // pre-v38 shape: backfill only touches rows like this
            row.catalogID = "jamendo-"    // the edge case: strips to "", not a real id
            try row.update(db)
        }
        try await store.dbQueue.write { db in try LibraryStore.backfillCatalogSources(db) }
        let backfilled = try await store.dbQueue.read { db in try XCTUnwrap(BlendCatalogTrack.fetchOne(db, key: key)) }
        XCTAssertEqual(backfilled.sourceKind, .jamendo)
        XCTAssertEqual(backfilled.providerTrackID, "7777", "falls back to trackID instead of writing \"\"")
    }

    func testMigrationListIncludesTheCatalog() {
        XCTAssertEqual(Schema.migrationOrder.last, "v47")
    }
}
