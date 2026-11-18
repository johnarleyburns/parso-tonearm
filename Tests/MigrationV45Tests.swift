import GRDB
import Testing
@testable import TonearmCore

/// v45: adds `source.lastBrowsedPath` — a plain nullable column, v42's exact style (no `CHECK`,
/// no backfill, no rebuild) — so reopening a remote source's browser can return to the last
/// folder visited instead of always restarting at the root.
@Suite struct MigrationV45Tests {
    @Test func testV45AddsTheColumnDefaultingToNullForExistingRows() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v44").migrate(queue)

        var sourceId: Int64 = 0
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, syncID)
                VALUES ('googleDrive', 'My Drive', ?, 0, 0, ?)
                """, arguments: [Date(), UUID().uuidString])
            sourceId = db.lastInsertedRowID
        }

        // Migrate to head (v45).
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            let columns = Set(try db.columns(in: "source").map(\.name))
            #expect(columns.contains("lastBrowsedPath"))

            let row = try #require(try Source.fetchOne(db, key: sourceId))
            #expect(row.lastBrowsedPath == nil, "an existing row must default to NULL, not a fabricated root path")
        }
    }

    @Test func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }

    @Test func testSetSourceLastBrowsedPathRoundTripsAndCanBeClearedToRoot() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try await store.insertSource(
            Source(id: nil, kind: .googleDrive, iaIdentifier: nil, originalURL: nil,
                   title: "My Drive", addedAt: Date(), lastResolvedAt: nil,
                   followUpdates: false, licenseText: nil, memberCapHit: false))
        let sourceId = try #require(source.id)

        try await store.setSourceLastBrowsedPath(id: sourceId, path: "folder/abc123")
        var fetched = try await store.allSources().first { $0.id == sourceId }
        #expect(fetched?.lastBrowsedPath == "folder/abc123")

        try await store.setSourceLastBrowsedPath(id: sourceId, path: nil)
        fetched = try await store.allSources().first { $0.id == sourceId }
        #expect(fetched?.lastBrowsedPath == nil, "nil must clear it back to root, not leave the stale folder")
    }
}
