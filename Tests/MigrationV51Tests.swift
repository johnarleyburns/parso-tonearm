import GRDB
import Testing
@testable import TonearmCore

/// v51: drops `starter_identity` (added in v47). The bundled Jamendo starter pack
/// (`StarterLibrary`/`mergeStarterLibrary`, and everything that wrote to it) is removed entirely
/// — on-device indexing of the user's own library is the sole source going forward.
/// `starter_identity` was this mechanism's own match key (provider+providerTrackID), with no
/// other reader or writer anywhere in the codebase.
@Suite struct MigrationV51Tests {
    @Test func testV51DropsTheStarterIdentityTable() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v50").migrate(queue)

        try queue.read { db throws in
            #expect(try db.tableExists("starter_identity"))
        }

        // Migrate to head (v51).
        try Schema.migrator().migrate(queue)

        try queue.read { db throws in
            #expect(!(try db.tableExists("starter_identity")))
        }
    }

    @Test func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }
}
