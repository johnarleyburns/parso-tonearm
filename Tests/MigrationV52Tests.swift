import GRDB
import XCTest
@testable import TonearmCore

/// v52: adds `watch`/`folderBookmark` columns to `sources`. Folder imports no longer
/// auto-create/populate a playlist (real report: "do not add any of the files shown to a
/// playlist automatically"), so "watch this folder" moves onto `Source` itself — additively,
/// mirroring `Playlist.watch`/`folderBookmark`'s own column types exactly.
final class MigrationV52Tests: XCTestCase {
    func testV52AddsWatchAndFolderBookmarkColumnsToSources() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v51").migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "source").map(\.name)
            XCTAssertFalse(columns.contains("watch"))
            XCTAssertFalse(columns.contains("folderBookmark"))
        }

        // Migrate to head (v52).
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "source").map(\.name)
            XCTAssertTrue(columns.contains("watch"))
            XCTAssertTrue(columns.contains("folderBookmark"))
        }
    }

    func testExistingSourceRowsDefaultToNotWatched() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v51").migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, localIsFolder)
                VALUES ('local', 'Existing Folder', ?, 0, 0, 1)
                """, arguments: [Date()])
        }

        try Schema.migrator().migrate(queue)

        let watch: Int? = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT watch FROM source WHERE title = 'Existing Folder'")
        }
        XCTAssertEqual(watch, 0, "pre-existing rows must default to not watched, not NULL/crash")
    }

    func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }
}
