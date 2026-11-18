import GRDB
import Testing

@testable import TonearmCore

@Suite struct SchemaMigrationV26Tests {
    @Test func testV26AddsCrateMembershipWithoutChangingExistingPlaylists() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v25").migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playlist (title, kind, folderBookmark, watch)
                    VALUES ('Existing', 'manual', NULL, 0)
                    """)
        }

        try Schema.migrator().migrate(queue)

        try queue.read { db throws in
            #expect(try db.columns(in: "playlist").contains { $0.name == "isInCrate" })
            let row = try Row.fetchOne(db, sql: "SELECT isInCrate FROM playlist WHERE title = 'Existing'")
            #expect(row?["isInCrate"] as Bool? == false)
        }
    }
}
