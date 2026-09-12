import XCTest
import GRDB
import TonearmCore

@testable import TonearmDJ

/// Commit 5.9 — gig crates (plan 5.9, §41.17, FR-PLIST-9, FR-ANL-9, FR-LIB-8):
/// promotion from a playlist with per-track readiness, the list/detail roll-ups,
/// `lastPerformedAt` (the LRU clock), and the FR-LIB-8 `audioCached` gate
/// stamped at promotion time — a partially-cached remote track is never ready.
///
/// C02 (session 14): `gig_crate_track.trackID` (copied from
/// `playlist_item.trackID`) is a **core** `LibraryStore` track id since
/// dj_v8 — so every fixture here seeds real core tracks/assets (not DJ-local
/// `DJTrack`/`DJAsset` rows keyed by a DJ-local id space that crate members
/// no longer live in) and `GigCrateRepository` is given a core `library`
/// dependency to resolve them.
final class GigCrateTests: XCTestCase {

    // MARK: - Helpers

    private struct Environment {
        let pool: DatabasePool
        let library: LibraryStore
        let dir: URL
        let repository: GigCrateRepository
    }

    private func makeEnvironment() throws -> Environment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GigCrateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        let library = try LibraryStore(inMemory: true)
        return Environment(pool: pool, library: library, dir: dir,
                           repository: GigCrateRepository(pool: pool, library: library))
    }

    /// Seeds `titles.count` **core** tracks (via `LibraryStore`), an ordered
    /// DJ playlist over their core track ids (mirroring what
    /// `PlaylistCrateImporter`/dj_v8 actually store in `playlist_item`), and
    /// per-track core `Asset`s. `cachedTitles` get a real on-disk file +
    /// bookmark (FR-LIB-8 cached); tracks without one have no asset (never
    /// ready).
    @discardableResult
    private func seedPlaylist(_ env: Environment, titles: [String],
                              cachedTitles: Set<String> = []) async throws -> Int64 {
        let source = try await env.library.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        var coreTrackIDsBuilder: [String: Int64] = [:]
        for title in titles {
            let track = try await env.library.insertTrack(Track(
                id: nil, albumId: nil, sourceId: source.id!, title: title, trackNo: nil,
                discNo: nil, durationSec: 180, codec: "WAV", sampleRate: 44_100,
                bitDepthOrBitrate: nil, sortKey: title))
            coreTrackIDsBuilder[title] = track.id!
            if cachedTitles.contains(title) {
                let url = env.dir.appendingPathComponent("\(title).wav")
                try Data([0, 1, 2, 3]).write(to: url)
                _ = try await env.library.insertAsset(Asset(
                    id: nil, trackId: track.id!, kind: .localRef,
                    bookmark: BookmarkVault.makeBookmark(for: url), relPath: nil,
                    remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil))
            }
        }
        let coreTrackIDs = coreTrackIDsBuilder
        let now = Date()
        return try await env.pool.write { db in
            var playlist = DJPlaylist(syncID: UUID().uuidString,
                                      title: "Test playlist",
                                      createdAt: now, updatedAt: now)
            try playlist.insert(db)
            guard let playlistID = playlist.id else { return 0 }
            for (index, title) in titles.enumerated() {
                var item = DJPlaylistItem(playlistID: playlistID,
                                          trackID: coreTrackIDs[title]!, position: index + 1)
                try item.insert(db)
            }
            return playlistID
        }
    }

    /// Gives an existing core track a fresh on-disk file + bookmark asset —
    /// the "the file lands after promotion" refresh scenario.
    private func addCoreAsset(_ env: Environment, trackID: Int64, fileName: String) async throws {
        let url = env.dir.appendingPathComponent(fileName)
        try Data([7]).write(to: url)
        _ = try await env.library.insertAsset(Asset(
            id: nil, trackId: trackID, kind: .localRef,
            bookmark: BookmarkVault.makeBookmark(for: url), relPath: nil,
            remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil))
    }

    private func coreTrackID(_ env: Environment, title: String) async throws -> Int64 {
        let rows = try await env.library.allTrackRows()
        return try XCTUnwrap(rows.first { $0.track.title == title }).id
    }

    // MARK: - Promotion (FR-PLIST-9)

    func testPromoteCopiesPlaylistItemsInOrder() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let playlistID = try await seedPlaylist(env, titles: ["a", "b", "c"], cachedTitles: ["a", "b"])

        let crateID = try await env.repository.promote(playlistID: playlistID,
                                                        name: "Saturday",
                                                        storageBudgetBytes: 4_000_000_000)
        let fetchedDetail = try await env.repository.detail(crateID: crateID)
        let detail = try XCTUnwrap(fetchedDetail)
        XCTAssertEqual(detail.crate.name, "Saturday")
        XCTAssertEqual(detail.trackCount, 3)
        XCTAssertEqual(detail.tracks.map(\.position), [1, 2, 3])
        XCTAssertEqual(detail.tracks.map(\.title), ["a", "b", "c"],
                       "titles resolve through the core LibraryStore, not a DJ-local track row")
        XCTAssertEqual(detail.cachedCount, 2, "FR-LIB-8 stamped at promotion")
        XCTAssertEqual(detail.crate.storageBudgetBytes, 4_000_000_000)
        XCTAssertEqual(detail.crate.lastPerformedAt, nil, "a fresh crate has no performance date")
    }

    func testPromotionComputesFRLIB8GateHonestly() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let playlistID = try await seedPlaylist(env, titles: ["onDisk", "noAsset", "gone"])
        // "gone" gets a bookmark to a file we then delete → not cached.
        let goneID = try await coreTrackID(env, title: "gone")
        let goneURL = env.dir.appendingPathComponent("gone.wav")
        try Data([9]).write(to: goneURL)
        _ = try await env.library.insertAsset(Asset(
            id: nil, trackId: goneID, kind: .localRef,
            bookmark: BookmarkVault.makeBookmark(for: goneURL), relPath: nil,
            remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil))
        try FileManager.default.removeItem(at: goneURL)

        let crateID = try await env.repository.promote(playlistID: playlistID,
                                                        name: "Honest",
                                                        storageBudgetBytes: 4_000_000_000)
        let fetchedDetail = try await env.repository.detail(crateID: crateID)
        let detail = try XCTUnwrap(fetchedDetail)
        let byTitle = Dictionary(uniqueKeysWithValues: detail.tracks.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["onDisk"]?.audioCached, false, "no asset → not cached")
        XCTAssertEqual(byTitle["noAsset"]?.audioCached, false, "no asset → not cached")
        XCTAssertEqual(byTitle["gone"]?.audioCached, false,
                       "a bookmark whose file is gone is not cached — honest absence")
    }

    /// The C02 regression test: `isAudioCached` must resolve a crate track's
    /// FR-LIB-8 state against the **core** `LibraryStore` asset for its
    /// (core) track id, not a DJ-local `DJAsset` row — which, since dj_v8,
    /// never exists for a crate member at all.
    func testAudioCachedResolvesAgainstCoreImportedTrack() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let playlistID = try await seedPlaylist(env, titles: ["cached-on-core"],
                                                cachedTitles: ["cached-on-core"])
        let coreID = try await coreTrackID(env, title: "cached-on-core")

        // Confirm this is genuinely a core-only track: no DJ-local `track`/
        // `asset` catalog table exists at all anymore (the bug's blind spot;
        // C02 deleted the DJ-local catalog tables outright).
        let hasTrackTable = try await env.pool.read { db in try db.tableExists("track") }
        let hasAssetTable = try await env.pool.read { db in try db.tableExists("asset") }
        XCTAssertFalse(hasTrackTable)
        XCTAssertFalse(hasAssetTable)

        let crateID = try await env.repository.promote(playlistID: playlistID,
                                                        name: "Core Only",
                                                        storageBudgetBytes: 4_000_000_000)
        // Read the raw gig_crate_track row directly (bypassing the title
        // join) so this assertion is pinned to the stamped flag itself.
        let stamped = try await env.pool.read { db in
            try GigCrateTrack
                .filter(Column("gigCrateID") == crateID && Column("trackID") == coreID)
                .fetchOne(db)
        }
        XCTAssertEqual(stamped?.audioCached, true,
                       "a promoted crate track's cache status must resolve via the core library")
    }

    func testRefreshAudioCachedReStampsFromDisk() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let playlistID = try await seedPlaylist(env, titles: ["a", "b"], cachedTitles: ["a"])
        let crateID = try await env.repository.promote(playlistID: playlistID,
                                                        name: "C", storageBudgetBytes: 4_000_000_000)
        var fetchedDetail = try await env.repository.detail(crateID: crateID)
        var detail = try XCTUnwrap(fetchedDetail)
        XCTAssertEqual(detail.cachedCount, 1)

        // "b" gains its file on disk → a refresh picks it up.
        let bID = try await coreTrackID(env, title: "b")
        try await addCoreAsset(env, trackID: bID, fileName: "b.wav")
        try await env.repository.refreshAudioCached(crateID: crateID)
        fetchedDetail = try await env.repository.detail(crateID: crateID)
        detail = try XCTUnwrap(fetchedDetail)
        XCTAssertEqual(detail.cachedCount, 2)
        XCTAssertTrue(detail.tracks.first { $0.title == "b" }!.audioCached)
    }

    // MARK: - Readiness roll-ups

    func testDetailRollUpsReflectStemsState() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let playlistID = try await seedPlaylist(env, titles: ["a", "b", "c"])
        let crateID = try await env.repository.promote(playlistID: playlistID,
                                                        name: "S", storageBudgetBytes: 4_000_000_000)

        let tracks = try await env.repository.trackRows(crateID: crateID)
        XCTAssertEqual(tracks.filter { $0.stems == .pending }.count, 3)

        try env.repository.setStemsState(crateID: crateID, trackID: tracks[0].trackID,
                                         state: .ready, bytes: 5_000_000)
        try env.repository.setStemsState(crateID: crateID, trackID: tracks[1].trackID,
                                         state: .running)

        let fetchedDetail = try await env.repository.detail(crateID: crateID)
        let detail = try XCTUnwrap(fetchedDetail)
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
        _ = try await env.pool.write { db in
            var crate = GigCrate(syncID: UUID().uuidString, name: "C",
                                 storageBudgetBytes: 4_000_000_000,
                                 createdAt: now)
            try crate.insert(db)
            return crate.id!
        }

        // LRU = oldest performed first; a never-performed crate is the oldest.
        let lru = try await env.repository.cratesByLRU(excluding: [])
        XCTAssertEqual(lru.map(\.name), ["C", "B", "A"])

        // Performing A refreshes its clock → it moves behind B and C.
        try env.repository.markPerformed(crateID: aID,
                                         at: now.addingTimeInterval(-100))
        let after = try await env.repository.cratesByLRU(excluding: [])
        XCTAssertEqual(after.map(\.name), ["C", "B", "A"])

        // Protected crates are never candidates.
        let protected = try await env.repository.cratesByLRU(excluding: [bID])
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
        let playlistID = try await seedPlaylist(env, titles: ["x"])
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
        let playlistID = try await seedPlaylist(env, titles: ["a", "b", "c"])
        let crateID = try await env.repository.promote(playlistID: playlistID,
                                                        name: "P", storageBudgetBytes: 4_000_000_000)
        let tracks = try await env.repository.trackRows(crateID: crateID)
        try env.repository.setStemsState(crateID: crateID, trackID: tracks[0].trackID,
                                         state: .ready, bytes: 2_000_000)
        let fetchedDetail = try await env.repository.detail(crateID: crateID)
        let detail = try XCTUnwrap(fetchedDetail)
        // 1 ready (2 MB on disk) + 2 pending at ~13 MB/track.
        XCTAssertEqual(detail.projectedStemBytes,
                       2_000_000 + 2 * StorageBudgetService.estimatedStemsBytesPerTrack)
    }
}
