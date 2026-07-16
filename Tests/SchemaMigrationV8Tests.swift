import GRDB
import XCTest

@testable import TonearmCore

final class SchemaMigrationV8Tests: XCTestCase {

    func testFreshSchemaHasArtistAndMetadataColumns() async throws {
        let store = try LibraryStore(inMemory: true)

        try await store.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("artist"))
            XCTAssertTrue(try db.columns(in: "album").contains { $0.name == "artistId" })
            XCTAssertTrue(try db.columns(in: "album").contains { $0.name == "albumArtist" })
            XCTAssertTrue(try db.columns(in: "album").contains { $0.name == "genre" })
            XCTAssertTrue(try db.columns(in: "track").contains { $0.name == "artistId" })
            XCTAssertTrue(try db.columns(in: "track").contains { $0.name == "genre" })
            XCTAssertTrue(try db.columns(in: "track").contains { $0.name == "composer" })
        }
    }

    func testMigratesV7AlbumsIntoDedupedArtistsWithoutDataLoss() throws {
        let dbQueue = try makeV7Database()
        try seedLegacyRows(dbQueue)

        let before = try dbQueue.read { db in
            (
                albums: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album") ?? 0,
                tracks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? 0
            )
        }

        try Schema.migrator().migrate(dbQueue)

        try dbQueue.read { db in
            let afterAlbums = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album") ?? 0
            let afterTracks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? 0
            XCTAssertEqual(afterAlbums, before.albums)
            XCTAssertEqual(afterTracks, before.tracks)

            let artistRows = try Row.fetchAll(
                db, sql: "SELECT id, name, sortName FROM artist ORDER BY sortName")
            let artistNames = artistRows.map { $0["name"] as String }
            XCTAssertEqual(Set(artistNames), ["A", "B", "The Beatles", "Various Artists"])
            XCTAssertEqual(
                artistRows.first { ($0["name"] as String) == "The Beatles" }?["sortName"], "Beatles"
            )

            let revolverArtistID: Int64? = try Row.fetchOne(
                db,
                sql: "SELECT artistId FROM album WHERE title = 'Revolver'"
            )?["artistId"]
            let abbeyArtistID: Int64? = try Row.fetchOne(
                db,
                sql: "SELECT artistId FROM album WHERE title = 'Abbey Road'"
            )?["artistId"]
            XCTAssertNotNil(revolverArtistID)
            XCTAssertEqual(
                revolverArtistID, abbeyArtistID, "case variants should reuse one artist row")

            let legacyArtist: String? = try Row.fetchOne(
                db,
                sql: "SELECT artist FROM album WHERE title = 'Revolver'"
            )?["artist"]
            let albumArtist: String? = try Row.fetchOne(
                db,
                sql: "SELECT albumArtist FROM album WHERE title = 'Revolver'"
            )?["albumArtist"]
            XCTAssertEqual(legacyArtist, "The Beatles")
            XCTAssertEqual(albumArtist, "The Beatles")

            let brokenAlbumRefs =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM track
                        LEFT JOIN album ON album.id = track.albumId
                        WHERE track.albumId IS NOT NULL AND album.id IS NULL
                        """) ?? -1
            XCTAssertEqual(brokenAlbumRefs, 0)

            let brokenArtistRefs =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM track
                        LEFT JOIN artist ON artist.id = track.artistId
                        WHERE track.artistId IS NOT NULL AND artist.id IS NULL
                        """) ?? -1
            XCTAssertEqual(brokenArtistRefs, 0)

            let knownArtistTracksWithoutArtist =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM track
                        JOIN album ON album.id = track.albumId
                        WHERE album.artist IS NOT NULL
                          AND TRIM(album.artist) <> ''
                          AND track.artistId IS NULL
                        """) ?? -1
            XCTAssertEqual(knownArtistTracksWithoutArtist, 0)
        }
    }

    private func makeV7Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(configuration: config)
        try Schema.migrator(upTo: "v7").migrate(dbQueue)
        return dbQueue
    }

    private func seedLegacyRows(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source (id, kind, title, addedAt, followUpdates, memberCapHit, localIsFolder, syncID)
                    VALUES (1, 'local', 'Legacy', ?, 0, 0, 0, 'SRC-1')
                    """, arguments: [Date(timeIntervalSince1970: 1_000)])

            let albums: [(Int64, String, String?)] = [
                (1, "Revolver", "The Beatles"),
                (2, "Abbey Road", "the beatles"),
                (3, "Compilation", "VA"),
                (4, "Collab", "A feat. B"),
                (5, "Blank", "   "),
            ]
            for (id, title, artist) in albums {
                try db.execute(
                    sql: """
                        INSERT INTO album (id, sourceId, title, artist, year, artworkId, syncID)
                        VALUES (?, 1, ?, ?, 1969, ?, ?)
                        """, arguments: [id, title, artist, "art-\(id)", "ALB-\(id)"])
            }

            let tracks: [(Int64, Int64?, String)] = [
                (1, 1, "Taxman"),
                (2, 2, "Come Together"),
                (3, 3, "Track One"),
                (4, 4, "Feature"),
                (5, 5, "Untitled"),
            ]
            for (id, albumID, title) in tracks {
                try db.execute(
                    sql: """
                        INSERT INTO track
                            (id, albumId, sourceId, title, trackNo, discNo, durationSec,
                             codec, sampleRate, bitDepthOrBitrate, sortKey, syncID)
                        VALUES (?, ?, 1, ?, ?, 1, 180.0, 'flac', 44100, '16', ?, ?)
                        """,
                    arguments: [
                        id, albumID, title, Int(id), String(format: "%04d", id), "TRK-\(id)",
                    ])
            }
        }
    }
}
