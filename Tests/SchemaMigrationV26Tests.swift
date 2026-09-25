import GRDB
import XCTest

@testable import TonearmCore

final class SchemaMigrationV26Tests: XCTestCase {
    func testV26AddsCrateMembershipWithoutChangingExistingPlaylists() throws {
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

        try queue.read { db in
            XCTAssertTrue(try db.columns(in: "playlist").contains { $0.name == "isInCrate" })
            let row = try Row.fetchOne(db, sql: "SELECT isInCrate FROM playlist WHERE title = 'Existing'")
            XCTAssertEqual(row?["isInCrate"] as Bool?, false)
        }
    }
}
