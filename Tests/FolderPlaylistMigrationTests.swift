import GRDB
import XCTest

@testable import TonearmCore

final class FolderPlaylistMigrationTests: XCTestCase {
    func testMigrationLinksFolderPlaylistsBySourceAndPreservesItems() throws {
        let db = try DatabaseQueue()
        try Schema.migrator(upTo: "v12").migrate(db)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO source (id, kind, title, addedAt, followUpdates, memberCapHit, localIsFolder)
                VALUES (1, 'local', 'Music', datetime('now'), 0, 0, 1)
                """)
            try db.execute(sql: """
                INSERT INTO album (id, sourceId, title) VALUES (1, 1, 'Music')
                """)
            try db.execute(sql: """
                INSERT INTO track (id, albumId, sourceId, title, sortKey)
                VALUES (1, 1, 1, 'Track', 'Track')
                """)
            try db.execute(sql: """
                INSERT INTO playlist (id, title, kind, folderBookmark, watch)
                VALUES (1, 'Music', 'folder', NULL, 1)
                """)
            try db.execute(sql: """
                INSERT INTO playlist_item (playlistId, position, trackId, sectionTitle)
                VALUES (1, 0, 1, 'Disc 1')
                """)
        }

        try Schema.migrator().migrate(db)

        try db.read { db in
            let sourceID: Int64? = try Row.fetchOne(db, sql: "SELECT sourceId FROM playlist WHERE id = 1")?["sourceId"]
            XCTAssertEqual(sourceID, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_item WHERE playlistId = 1"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT sectionTitle FROM playlist_item WHERE playlistId = 1"), "Disc 1")
        }
    }
}
