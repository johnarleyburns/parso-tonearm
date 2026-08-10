import XCTest
import GRDB

@testable import TonearmDJ

final class DJSchemaTests: XCTestCase {
    func testMigrationOrderIsAppendOnly() {
        XCTAssertEqual(DJSchema.migrationOrder, ["dj_v1"])
        XCTAssertEqual(DJSchema.migrator().migrations, ["dj_v1"])
    }

    func testApplyingAllMigrationsCreatesRelationalCoreTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)

        let expectedTables = [
            "artist", "album", "track", "track_artist", "genre", "track_genre",
            "folder", "asset", "import_event",
            "cue_point", "hot_cue_bank", "loop", "grid_correction",
            "playlist", "playlist_item", "smart_crate", "crate_rule",
            "auto_playlist_brief", "auto_playlist_result", "auto_playlist_item", "auto_playlist_rejection",
            "gig_crate", "gig_crate_track",
            "rating", "tag", "track_tag", "app_setting",
        ]
        try db.read { db in
            for table in expectedTables {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
        }
    }

    func testTrackDefaultsMatchDDL() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        let now = Date()
        var track = DJTrack(
            syncID: UUID().uuidString,
            title: "Halcyon",
            contentHash: "abc",
            sortKey: "halcyon",
            addedAt: now,
            updatedAt: now
        )
        try db.write { try track.insert($0) }

        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT analysisVersion, embeddingVersion, analysisState, stemState FROM track WHERE id = ?", arguments: [track.id!])
        }
        let fetched = try XCTUnwrap(row)
        XCTAssertEqual(fetched["analysisVersion"] as? Int64, 0)
        XCTAssertEqual(fetched["embeddingVersion"] as? Int64, 0)
        XCTAssertEqual(fetched["analysisState"] as? String, "pending")
        XCTAssertEqual(fetched["stemState"] as? String, "none")
    }
}
