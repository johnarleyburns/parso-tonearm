import GRDB
import XCTest
@testable import TonearmCore

final class MigrationV14Tests: XCTestCase {
    func testV14AddsFolderPathWithoutLosingSources() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v13").migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                    localIsFolder, syncID)
                VALUES ('local', 'Music', ?, 0, 0, 1, ?)
                """, arguments: [Date(), UUID().uuidString])
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            XCTAssertNotNil(try db.columns(in: "source").first { $0.name == "folderPath" })
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source"), 1)
        }
    }
}
