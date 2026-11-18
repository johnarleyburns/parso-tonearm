import GRDB
import Testing
@testable import TonearmCore

/// v52: adds `watch`/`folderBookmark` columns to `sources`. Folder imports no longer
/// auto-create/populate a playlist (real report: "do not add any of the files shown to a
/// playlist automatically"), so "watch this folder" moves onto `Source` itself — additively,
/// mirroring `Playlist.watch`/`folderBookmark`'s own column types exactly.
@Suite struct MigrationV52Tests {
    @Test func testV52AddsWatchAndFolderBookmarkColumnsToSources() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v51").migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "source").map(\.name)
            #expect(!columns.contains("watch"))
            #expect(!columns.contains("folderBookmark"))
        }

        // Migrate to head (v52).
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "source").map(\.name)
            #expect(columns.contains("watch"))
            #expect(columns.contains("folderBookmark"))
        }
    }

    @Test func testExistingSourceRowsAreNotWatchedAfterMigration() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v51").migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, localIsFolder)
                VALUES ('local', 'Existing Folder', ?, 0, 0, 1)
                """, arguments: [Date()])
        }

        try Schema.migrator().migrate(queue)

        // The new column is nullable with no SQL-level default (see the migration's own
        // comment) — `ALTER TABLE ADD COLUMN` leaves it NULL for pre-existing rows, which reads
        // back as `nil`/"not watched" at the Swift level, not a crash.
        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT watch FROM source WHERE title = 'Existing Folder'")
        }
        let watch: Int? = row?["watch"]
        #expect(watch == nil, "pre-existing rows must read back as not watched (nil), not a crash or a stray true")
    }

    @Test func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }
}
