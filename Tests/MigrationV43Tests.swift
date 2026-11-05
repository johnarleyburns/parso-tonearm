import GRDB
import XCTest
@testable import TonearmCore

/// v43: drops `discovery_transition_profile` (added in v40). Everything that wrote to it
/// (`BoundedIndexWorker.persistTransitionProfileBestEffort`, two extra `FullAnalysis.run` calls
/// per track for a head/tail window) fed `ProfileTransitionPlanner`/`DropAwareEdgePlanner`,
/// confirmed to have zero production callers on either the write or read side — indexing now
/// computes only bpm/beatgrid/key/energy (`LeanAnalysis`), and this table is removed entirely.
final class MigrationV43Tests: XCTestCase {
    func testV43DropsTheTransitionProfileTable() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v42").migrate(queue)

        try queue.read { db in
            XCTAssertTrue(try db.tableExists("discovery_transition_profile"))
        }

        // Migrate to head (v43).
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            XCTAssertFalse(try db.tableExists("discovery_transition_profile"))
        }
    }

    func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }
}
