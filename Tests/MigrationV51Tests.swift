import GRDB
import XCTest
@testable import TonearmCore

/// v51: drops `starter_identity` (added in v47). The bundled Jamendo starter pack
/// (`StarterLibrary`/`mergeStarterLibrary`, and everything that wrote to it) is removed entirely
/// — on-device indexing of the user's own library is the sole source going forward.
/// `starter_identity` was this mechanism's own match key (provider+providerTrackID), with no
/// other reader or writer anywhere in the codebase.
final class MigrationV51Tests: XCTestCase {
    func testV51DropsTheStarterIdentityTable() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v50").migrate(queue)

        try queue.read { db in
            XCTAssertTrue(try db.tableExists("starter_identity"))
        }

        // Migrate to head (v51).
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            XCTAssertFalse(try db.tableExists("starter_identity"))
        }
    }

    func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }
}
