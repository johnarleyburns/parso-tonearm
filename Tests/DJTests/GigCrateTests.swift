import XCTest
import GRDB
import TonearmCore

@testable import TonearmDJ

/// Commit 5.9 — gig crates (plan 5.9, §41.17, FR-PLIST-9, FR-ANL-9, FR-LIB-8):
/// promotion from a playlist with per-track readiness, the list/detail roll-ups,
/// `lastPerformedAt` (the LRU clock), and the FR-LIB-8 `audioCached` gate
/// stamped at promotion time — a partially-cached remote track is never ready.
final class GigCrateTests: XCTestCase {

    // MARK: - Helpers

    private struct Environment {
        let pool: DatabasePool
        let dir: URL
        let repository: GigCrateRepository
    }

    private func makeEnvironment() throws -> Environment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GigCrateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        return Environment(pool: pool, dir: dir,
                           repository: GigCrateRepository(pool: pool))
    }

    /// Seeds `count` tracks, an ordered playlist over them, and per-track
    /// assets. `cachedTitles` get a real on-disk file + bookmark (FR-LIB-8
    /// cached); tracks without one have no asset (never ready).
    private func seedPlaylist(_ env: Environment, titles: [String],
                              cachedTitles: Set<String> = []) throws -> Int64 {
        let now = Date()
        return try env.pool.write { db in
            var playlist = DJPlaylist(syncID: UUID().uuidString,
                                      title: "Test playlist",
                                      createdAt: now, updatedAt: now)
            try playlist.insert(db)
            guard let playlistID = playlist.id else { return 0 }
            for (index, title) in titles.enumerated() {
                var track = DJTrack(syncID: UUID().uuidString, title: title,
                                    contentHash: "hash-\(title)", sortKey: title,
                                    addedAt: now, updatedAt: now)
                try track.insert(db)
                let trackID = track.id!
                if cachedTitles.contains(title) {
                    let url = env.dir.appendingPathComponent("\(title).wav")
                    try Data([0, 1, 2, 3]).write(to: url)
                    var asset = DJAsset(trackID: trackID,
                                        bookmark: BookmarkVault.makeBookmark(for: url),
                                        relPath: "\(title).wav")
                    try asset.insert(db)
                }
                var item = DJPlaylistItem(playlistID: playlistID,
                                          trackID: trackID, position: index + 1)
                try item.insert(db)
            }
            return playlistID
        }
    }

    private func insertTrack(_ db: Database, title: String) throws -> Int64 {
        var track = DJTrack(syncID: UUID().uuidString, title: title,
                            contentHash: "hash-\(title)", sortKey: title,
                            addedAt: Date(), updatedAt: Date())
        try track.insert(db)
        return track.id!
    }

    private func insertPlaylist(_ db: Database, title: String) throws -> Int64 {
        var playlist = DJPlaylist(syncID: UUID().uuidString, title: title,
                                  createdAt: Date(), updatedAt: Date())
        try playlist.insert(db)
        return playlist.id!
    }

    // MARK: - Promotion (FR-PLIST-9)

    func testPromoteCopiesPlaylistItemsInOrder() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let playlistID = try seedPlaylist(env, titles: ["a", "b", "c"], cachedTitles: ["a", "b"])

        let crateID = try env.repository.promote(playlistID: playlistID,
                                                 name: "Saturday",
                                                 storageBudgetBytes: 4_000_000_000)
        let detail = try XCTUnwrap(try env.repository.detail(crateID: crateID))
        XCTAssertEqual(detail.crate.name, "Saturday")
        XCTAssertEqual(detail.trackCount, 3)
        XCTAssertEqual(detail.tracks.map(\.position), [1, 2, 3])
        XCTAssertEqual(detail.tracks.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(detail.cachedCount, 2, "FR-LIB-8 stamped at promotion")
        XCTAssertEqual(detail.crate.storageBudgetBytes, 4_000_000_000)
        XCTAssertEqual(detail.crate.lastPerformedAt, nil, "a fresh crate has no performance date")
    }

    func testPromotionComputesFRLIB8GateHonestly() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let playlistID = try seedPlaylist(env, titles: ["onDisk", "noAsset", "gone"])
        // "gone" gets a bookmark to a file we then delete → not cached.
        try await env.pool.write { db in
            let url = env.dir.appendingPathComponent("gone.wav")
            try Data([9]).write(to: url)
            let trackID = try DJTrack.fetchOne(db,
                                               sql: "SELECT * FROM track WHERE title = 'gone'")!.id!
            var asset = DJAsset(trackID: trackID,
                                bookmark: BookmarkVault.makeBookmark(for: url),
                                relPath: "gone.wav")
            try asset.insert(db)
        }
        try FileManager.default.removeItem(at: env.dir.appendingPathComponent("gone.wav"))

        let crateID = try env.repository.promote(playlistID: playlistID,
                                                 name: "Honest",
                                                 storageBudgetBytes: 4_000_000_000)
        let detail = try XCTUnwrap(try env.repository.detail(crateID: crateID))
        let byTitle = Dictionary(uniqueKeysWithValues: detail.tracks.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["onDisk"]?.audioCached, false, "no asset → not cached")
        XCTAssertEqual(byTitle["noAsset"]?.audioCached, false, "no asset → not cached")
        XCTAssertEqual(byTitle["gone"]?.audioCached, false,
                       "a bookmark whose file is gone is not cached — honest absence")
    }

    func testRefreshAudioCachedReStampsFromDisk() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let playlistID = try seedPlaylist(env, titles: ["a", "b"], cachedTitles: ["a"])
        let crateID = try env.repository.promote(playlistID: playlistID,
                                                 name: "C", storageBudgetBytes: 4_000_000_000)
        var detail = try XCTUnwrap(try env.repository.detail(crateID: crateID))
        XCTAssertEqual(detail.cachedCount, 1)

        // "b" gains its file on disk → a refresh picks it up.
        try await env.pool.write { db in
            let trackID = try DJTrack.fetchOne(db, sql: "SELECT * FROM track WHERE title = 'b'")!.id!
            let url = env.dir.appendingPathComponent("b.wav")
            try Data([7]).write(to: url)
            var asset = DJAsset(trackID: trackID,
                                bookmark: BookmarkVault.makeBookmark(for: url),
                                relPath: "b.wav")
            try asset.insert(db)
        }
        try env.repository.refreshAudioCached(crateID: crateID)
        detail = try XCTUnwrap(try env.repository.detail(crateID: crateID))
        XCTAssertEqual(detail.cachedCount, 2)
        XCTAssertTrue(detail.tracks.first { $0.title == "b" }!.audioCached)
    }

    // MARK: - Readiness roll-ups

    func testDetailRollUpsReflectStemsState() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let playlistID = try seedPlaylist(env, titles: ["a", "b", "c"])
        let crateID = try env.repository.promote(playlistID: playlistID,
                                                 name: "S", storageBudgetBytes: 4_000_000_000)

        let tracks = try env.repository.trackRows(crateID: crateID)
        XCTAssertEqual(tracks.filter { $0.stems == .pending }.count, 3)

        try env.repository.setStemsState(crateID: crateID, trackID: tracks[0].trackID,
                                         state: .ready, bytes: 5_000_000)
        try env.repository.setStemsState(crateID: crateID, trackID: tracks[1].trackID,
                                         state: .running)

        let detail = try XCTUnwrap(try env.repository.detail(crateID: crateID))
        XCTAssertEqual(detail.stemsReadyCount, 1)
        XCTAssertEqual(detail.stemsBytes, 5_000_000)
        XCTAssertEqual(detail.analyzedCount, 0)

        let needing = try env.repository.tracksNeedingStems(crateID: crateID)
        XCTAssertEqual(needing.count, 2, "ready tracks are never re-queued")
        XCTAssertEqual(Set(needing.map(\.trackID)),
                       Set([tracks[1].trackID, tracks[2].trackID]))
        XCTAssertEqual(try env.repository.tracksNeedingStemsCount(crateID: crateID), 2)
    }

    // MARK: - lastPerformedAt / LRU ordering (FR-ANL-9)

    func testMarkPerformedDrivesLRUOrdering() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let now = Date()
        let aID: Int64 = try await env.pool.write { db in
            var crate = GigCrate(syncID: UUID().uuidString, name: "A",
                                 storageBudgetBytes: 4_000_000_000,
                                 lastPerformedAt: now.addingTimeInterval(-3600),
                                 createdAt: now)
            try crate.insert(db)
            return crate.id!
        }
        let bID: Int64 = try await env.pool.write { db in
            var crate = GigCrate(syncID: UUID().uuidString, name: "B",
                                 storageBudgetBytes: 4_000_000_000,
                                 lastPerformedAt: now.addingTimeInterval(-7200),
                                 createdAt: now)
            try crate.insert(db)
            return crate.id!
        }
        let cID: Int64 = try await env.pool.write { db in
            var crate = GigCrate(syncID: UUID().uuidString, name: "C",
                                 storageBudgetBytes: 4_000_000_000,
                                 createdAt: now)
            try crate.insert(db)
            return crate.id!
        }

        // LRU = oldest performed first; a never-performed crate is the oldest.
        let lru = try env.repository.cratesByLRU(excluding: [])
        XCTAssertEqual(lru.map(\.name), ["C", "B", "A"])

        // Performing A refreshes its clock → it moves behind B and C.
        try env.repository.markPerformed(crateID: aID,
                                         at: now.addingTimeInterval(-100))
        let after = try env.repository.cratesByLRU(excluding: [])
        XCTAssertEqual(after.map(\.name), ["C", "B", "A"])

        // Protected crates are never candidates.
        let protected = try env.repository.cratesByLRU(excluding: [bID])
        XCTAssertFalse(protected.map(\.name).contains("B"))
    }

    // MARK: - Seam conformance

    func testRepositoryConformsToTheViewModelSeam() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let repository = env.repository
        let seam: any GigCrateRepositing = repository
        let playlists = try await seam.playlists()
        XCTAssertTrue(playlists.isEmpty)
        _ = try await seam.crates()
        let nilDetail = try await seam.detail(crateID: 1)
        XCTAssertNil(nilDetail)
        // A promotion through the seam works end to end.
        let playlistID = try seedPlaylist(env, titles: ["x"])
        let crateID = try await seam.promote(playlistID: playlistID,
                                             name: "Seam", storageBudgetBytes: 4_000_000_000)
        try await seam.markPerformed(crateID: crateID)
        let detail = try await seam.detail(crateID: crateID)
        XCTAssertEqual(detail?.crate.lastPerformedAt?.timeIntervalSince1970 ?? 0 > 0, true)
    }

    // MARK: - Projection

    func testProjectedStemBytesCountsPendingTracks() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let playlistID = try seedPlaylist(env, titles: ["a", "b", "c"])
        let crateID = try env.repository.promote(playlistID: playlistID,
                                                 name: "P", storageBudgetBytes: 4_000_000_000)
        let tracks = try env.repository.trackRows(crateID: crateID)
        try env.repository.setStemsState(crateID: crateID, trackID: tracks[0].trackID,
                                         state: .ready, bytes: 2_000_000)
        let detail = try XCTUnwrap(try env.repository.detail(crateID: crateID))
        // 1 ready (2 MB on disk) + 2 pending at ~13 MB/track.
        XCTAssertEqual(detail.projectedStemBytes,
                       2_000_000 + 2 * StorageBudgetService.estimatedStemsBytesPerTrack)
    }
}
