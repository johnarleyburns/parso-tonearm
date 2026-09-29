import GRDB
import XCTest

@testable import TonearmCore

final class SchemaMigrationV31Tests: XCTestCase {
    func testPlaylistMixCascadesWithPlaylist() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v30").migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO playlist (title, kind, folderBookmark, watch) VALUES ('Mix', 'manual', NULL, 0)")
        }
        try Schema.migrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO playlist_mix (playlistId, shape, seed, lockedJSON, transitionOverridesJSON, updatedAt) VALUES (1, 'steady', 4, '{}', '{}', ?)", arguments: [Date()])
        }
        try queue.read { db in
            XCTAssertNotNil(try db.columns(in: "playlist_mix").first(where: { $0.name == "transitionOverridesJSON" }))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_mix"), 1)
        }
        try queue.write { db in try db.execute(sql: "DELETE FROM playlist WHERE id = 1") }
        try queue.read { db in XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_mix"), 0) }
    }
}
