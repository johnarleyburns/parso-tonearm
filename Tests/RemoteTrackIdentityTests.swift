import Foundation
import Testing
import GRDB
@testable import TonearmCore

@Suite struct RemoteTrackIdentityTests {
    // MARK: Pure identity rules
    @Test func testNodeIDIsTrimmedAndSourceNamespaced() throws {
        let a = try #require(RemoteTrackIdentity.canonical(sourceID: 1, nodeID: "  abc "))
        let b = try #require(RemoteTrackIdentity.canonical(sourceID: 1, nodeID: "abc"))
        let c = try #require(RemoteTrackIdentity.canonical(sourceID: 2, nodeID: "abc"))
        #expect(a == b)
        #expect(a != c)
        #expect(a.key != c.key)
        #expect(a != RemoteTrackIdentity.canonical(sourceID: 1, nodeID: "abd"))
    }

    @Test func testMissingOrUnsafeIdentityYieldsNone() {
        #expect(RemoteTrackIdentity.canonical(sourceID: 1, nodeID: "  ") == nil)
        #expect(RemoteTrackIdentity.canonical(sourceID: 1, nodeID: nil) == nil)
        #expect(RemoteTrackIdentity.canonical(sourceID: 1, nodeID: "now-playing-7") == nil)
        #expect(RemoteTrackIdentity.canonical(sourceID: 1, nodeID: nil, nodePath: "/a/b.mp3") == nil,
                     "path fallback is opt-in per provider")
        #expect(RemoteTrackIdentity.canonical(sourceID: 1, nodeID: nil,
                                                   nodePath: "https://x/y?sig=1", pathIsDurable: true) == nil)
    }

    @Test func testPathFallbackIsNormalized() throws {
        let a = RemoteTrackIdentity.canonical(sourceID: 1, nodeID: nil, nodePath: "/Music//a.mp3", pathIsDurable: true)
        let b = RemoteTrackIdentity.canonical(sourceID: 1, nodeID: "", nodePath: "Music/a.mp3/", pathIsDurable: true)
        #expect(a != nil)
        #expect(a == b)
    }

    // MARK: Upsert
    private func seed(_ store: LibraryStore, sources: Int = 1) async throws -> [Int64] {
        var ids: [Int64] = []
        for n in 0..<sources {
            let s = try await store.insertSource(Source(id: nil, kind: .dropbox, iaIdentifier: nil, originalURL: nil,
                title: "S\(n)", addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                licenseText: nil, memberCapHit: false))
            ids.append(try #require(s.id))
        }
        return ids
    }

    private func track(_ title: String) -> Track {
        Track(id: nil, albumId: nil, sourceId: 0, title: title, trackNo: 1, discNo: nil, durationSec: 100,
              codec: nil, sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "000001")
    }

    private func asset(_ node: String?, _ url: String) -> Asset {
        Asset(id: nil, trackId: 0, kind: .remote, bookmark: nil, relPath: nil, remoteURL: url, altRemoteURL: nil,
              sizeBytes: 5, unsupportedReason: nil, remoteNodeID: node, remoteNodePath: "p")
    }

    @Test func testRotatedURLReusesOneTrackAndRefreshesLocator() async throws {
        let store = try LibraryStore(inMemory: true)
        let src = try await seed(store)[0]
        let first = try await store.upsertRemoteTrack(sourceID: src, track: track("T"), asset: asset("n1", "https://a/1"))
        let second = try await store.upsertRemoteTrack(sourceID: src, track: track("T"), asset: asset("n1", "https://a/2?sig=z"))
        #expect(first.trackID == second.trackID)
        #expect(first.created)
        #expect(!second.created)
        let rows = try await store.tracks(forSource: src)
        #expect(rows.count == 1)
        #expect(rows[0].asset?.remoteURL == "https://a/2?sig=z")
        let idRows = try await store.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM remote_track_identity") }
        #expect(idRows == 1)
    }

    @Test func testDistinctIDsSameMetadataAndSameNodeInTwoSourcesStaySeparate() async throws {
        let store = try LibraryStore(inMemory: true)
        let srcs = try await seed(store, sources: 2)
        _ = try await store.upsertRemoteTrack(sourceID: srcs[0], track: track("Same"), asset: asset("a", "https://h/x"))
        _ = try await store.upsertRemoteTrack(sourceID: srcs[0], track: track("Same"), asset: asset("b", "https://h/x"))
        _ = try await store.upsertRemoteTrack(sourceID: srcs[1], track: track("Same"), asset: asset("a", "https://h/x"))
        let total = try await store.allTrackRows().count
        #expect(total == 3)
    }

    @Test func testConcurrentConnectionsCreateExactlyOneTrack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("db.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(10)
        let q1 = try DatabaseQueue(path: path, configuration: config)
        try Schema.migrator().migrate(q1)
        try q1.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, localIsFolder)
                VALUES ('dropbox', 'S', ?, 0, 0, 0)
                """, arguments: [Date()])
        }
        let q2 = try DatabaseQueue(path: path, configuration: config)
        let results = LockedBox<[Int64]>([])
        let sharedTrack = track("T")
        // Both writes start together on separate connections; `concurrentPerform`
        // joins them without a semaphore gate.
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let q = i == 0 ? q1 : q2
            let sharedAsset = asset("same", "https://u/\(i)")
            let outcome = try? q.write { db in
                try RemoteTrackUpsert.upsert(db: db, sourceID: 1, track: sharedTrack, asset: sharedAsset)
            }
            if let outcome { results.append(outcome.trackID) }
        }
        #expect(Set(results.value).count == 1)
        #expect(results.value.count == 2)
        // A "recreated process": a fresh connection still enforces the durable constraint.
        let q3 = try DatabaseQueue(path: path, configuration: config)
        try q3.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM remote_track_identity") == 1)
        }
        let again = try q3.write { try RemoteTrackUpsert.upsert(db: $0, sourceID: 1, track: track("T"),
                                                                asset: asset("same", "https://u/9")) }
        #expect(!again.created)
    }

    @Test func testIdentityConflictRollsBackWithoutOrphans() throws {
        let q = try DatabaseQueue()
        try Schema.migrator().migrate(q)
        try q.write { db in
            try db.execute(sql: "INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, localIsFolder) VALUES ('dropbox','S',?,0,0,0)", arguments: [Date()])
            // A stale mapping pointing at a different track makes the claim conflict.
            try db.execute(sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (1,'x','1')")
            try db.execute(sql: "INSERT INTO remote_track_identity VALUES (1, 'v1:id:k', 1)")
        }
        let outcome = try q.write { try RemoteTrackUpsert.upsert(db: $0, sourceID: 1, track: track("T"), asset: asset("k", "https://u")) }
        #expect(outcome.trackID == 1)
        try q.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE trackId <> 1") == 0)
        }
    }

    // MARK: Migration cleanup
    private func seedDuplicates() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let q = try DatabaseQueue(configuration: config)
        try Schema.migrator(upTo: "v49").migrate(q)
        try q.write { db in
            for kind in ["dropbox", "dropbox"] {
                try db.execute(sql: "INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, localIsFolder) VALUES (?,'S',?,0,0,0)", arguments: [kind, Date()])
            }
            for i in 1...8 {
                try db.execute(sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (1,'Dup','1')")
                try db.execute(sql: "INSERT INTO asset (trackId, kind, remoteURL, remoteNodeID) VALUES (?, 'remote', ?, 'node')", arguments: [i, "https://u/\(i)"])
            }
            // Same provider ID in another source, and two unidentified legacy rows.
            try db.execute(sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (2,'Dup','1')")
            try db.execute(sql: "INSERT INTO asset (trackId, kind, remoteURL, remoteNodeID) VALUES (9, 'remote', 'https://u/o', 'node')")
            for i in 10...11 {
                try db.execute(sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (1,'Dup','1')")
                try db.execute(sql: "INSERT INTO asset (trackId, kind, remoteURL) VALUES (?, 'remote', 'https://u/legacy')", arguments: [i])
            }
            // User data spread across duplicates; track 5 is the richest.
            try db.execute(sql: "INSERT INTO favorite (trackId, favoritedAt) VALUES (3, ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO favorite (trackId, favoritedAt) VALUES (5, ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO custom_artwork (trackId, artworkId) VALUES (2, 'art2')")
            for t in [1, 4, 5, 7] {
                try db.execute(sql: "INSERT INTO play_history (trackId, playedAt) VALUES (?, ?)", arguments: [t, Date()])
            }
            try db.execute(sql: "INSERT INTO playlist (title, kind, watch) VALUES ('P1','manual',0)")
            try db.execute(sql: "INSERT INTO playlist (title, kind, watch) VALUES ('P2','manual',0)")
            try db.execute(sql: "INSERT INTO playlist_item (playlistId, position, trackId) VALUES (1,0,1)")
            try db.execute(sql: "INSERT INTO playlist_item (playlistId, position, trackId) VALUES (1,1,6)")
            try db.execute(sql: "INSERT INTO playlist_item (playlistId, position, trackId) VALUES (2,0,8)")
            try db.execute(sql: "INSERT INTO cache_entry (assetId, relPath, byteRanges, complete, lastAccessedAt, createdAt) VALUES (7, 'f', x'', 1, ?, ?)", arguments: [Date(), Date()])
            try db.execute(sql: "INSERT INTO jump_back_in_dismissal (trackId, dismissedAt) VALUES (4, ?)", arguments: [Date()])
        }
        return q
    }

    @Test func testMigrationConsolidatesEightDuplicatesPreservingUserState() throws {
        let q = try seedDuplicates()
        try Schema.migrator().migrate(q)
        try q.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE sourceId = 1 AND id <= 8") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE sourceId = 2") == 1, "other source untouched")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE id IN (10, 11)") == 2, "unidentified legacy rows kept")
            let survivor = try #require(try Int64.fetchOne(db, sql: "SELECT trackId FROM remote_track_identity WHERE sourceId = 1"))
            #expect(survivor == 5, "richest user data wins")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite WHERE trackId = ?", arguments: [survivor]) == 1)
            #expect(try String.fetchOne(db, sql: "SELECT artworkId FROM custom_artwork WHERE trackId = ?", arguments: [survivor]) == "art2")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play_history WHERE trackId = ?", arguments: [survivor]) == 4)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_item WHERE playlistId = 1 AND trackId = ?", arguments: [survivor]) == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_item WHERE playlistId = 2 AND trackId = ?", arguments: [survivor]) == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cache_entry c JOIN asset a ON a.id = c.assetId WHERE a.trackId = ?", arguments: [survivor]) == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jump_back_in_dismissal WHERE trackId = ?", arguments: [survivor]) == 1)
            #expect(try String.fetchOne(db, sql: "SELECT remoteURL FROM asset WHERE trackId = ?", arguments: [survivor]) == "https://u/8")
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count == 0)
        }
        // Rerunning is a no-op.
        let report = try q.write { try RemoteTrackConsolidator.run(db: $0) }
        #expect(report.groupsMerged == 0)
        #expect(report.unidentifiedAssets == 2)
    }

    @Test func testFailureBeforeLoserDeletionRollsBackWholeGroup() throws {
        let q = try seedDuplicates()
        try Schema.migrator().migrate(q)
        // Re-create the duplicates post-migration by dropping the identity rows and adding rows.
        try q.write { db in
            try db.execute(sql: "DELETE FROM remote_track_identity")
            try db.execute(sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (1,'Dup','1')")
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO asset (trackId, kind, remoteURL, remoteNodeID) VALUES (?, 'remote', 'https://u/z', 'node')", arguments: [id])
            try db.execute(sql: "INSERT INTO favorite (trackId, favoritedAt) VALUES (?, ?)", arguments: [id, Date()])
        }
        let before = try q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM track") }
        do {
            _ = try q.write { try RemoteTrackConsolidator.run(db: $0, failBeforeDelete: true) }
            Issue.record("expected RemoteTrackConsolidator.run(failBeforeDelete: true) to throw")
        } catch {}
        try q.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") == before)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM remote_track_identity") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite") == 2)
        }
    }

    /// The production browse → persist route: two independently generated browse rows for one
    /// provider item with distinct temporary URLs resolve to one My Music track.
    @Test func testIngestRouteWithRotatingURLsKeepsOneTrack() async throws {
        let store = try LibraryStore(inMemory: true)
        let src = try await seed(store)[0]
        let allSources = try await store.allSources()
        let source = try #require(allSources.first { $0.id == src })
        var seen = Set<Int64>()
        for n in 0..<3 {
            let node = RemoteNode(id: "stable", title: "Song", path: "/Song.mp3", kind: .audio)
            let result = await RemotePlaylistIngest.persist(
                nodes: [node],
                resolve: { _ in ResolvedAsset(url: URL(string: "https://cdn/x?sig=\(n)")!, headers: [:],
                                              supportsByteRanges: true, sizeBytes: 1) },
                source: source, store: store)
            seen.formUnion(result.trackIDs)
        }
        #expect(seen.count == 1)
        let rows = try await store.allTrackRows()
        #expect(rows.count == 1)
        #expect(rows[0].asset?.remoteURL == "https://cdn/x?sig=2")
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
}
private extension LockedBox where T == [Int64] {
    func append(_ v: Int64) { lock.lock(); storage.append(v); lock.unlock() }
}
