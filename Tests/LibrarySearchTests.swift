import GRDB
import XCTest

@testable import TonearmCore

final class LibrarySearchTests: XCTestCase {

    func testSearchMatchesTitleArtistAlbumGenreAndFilename() async throws {
        let store = try LibraryStore(inMemory: true)
        let trackID = try await seedSearchFixture(into: store)

        let titleMatches = try await store.search("sinn").map(\.id)
        let artistMatches = try await store.search("Nina").map(\.id)
        let albumMatches = try await store.search("Pastel").map(\.id)
        let trackGenreMatches = try await store.search("Jazz").map(\.id)
        let albumGenreMatches = try await store.search("Soul").map(\.id)
        let filenameMatches = try await store.search("Hidden Filename").map(\.id)

        XCTAssertEqual(titleMatches, [trackID])
        XCTAssertEqual(artistMatches, [trackID])
        XCTAssertEqual(albumMatches, [trackID])
        XCTAssertEqual(trackGenreMatches, [trackID])
        XCTAssertEqual(albumGenreMatches, [trackID])
        XCTAssertEqual(filenameMatches, [trackID])
    }

    func testSearchRejectsEmptyAndPunctuationOnlyQueries() async throws {
        let store = try LibraryStore(inMemory: true)
        _ = try await seedSearchFixture(into: store)

        let emptyMatches = try await store.search("").map(\.id)
        let punctuationMatches = try await store.search("*** \" :").map(\.id)

        XCTAssertEqual(emptyMatches, [])
        XCTAssertEqual(punctuationMatches, [])
    }

    func testMigrationV9RebuildsExistingFTSRowsAcrossJoinedMetadata() throws {
        let dbQueue = try makeV8Database()
        try seedV8SearchRows(dbQueue)

        try Schema.migrator().migrate(dbQueue)

        try dbQueue.read { db in
            XCTAssertEqual(try matchedTrackIDs(db, expression: "\"Sinn\"*"), [1])
            XCTAssertEqual(try matchedTrackIDs(db, expression: "\"Nina\"*"), [1])
            XCTAssertEqual(try matchedTrackIDs(db, expression: "\"Pastel\"*"), [1])
            XCTAssertEqual(try matchedTrackIDs(db, expression: "\"Soul\"*"), [1])
            XCTAssertEqual(try matchedTrackIDs(db, expression: "\"Migrated\"* \"File\"*"), [1])
        }
    }

    private func seedSearchFixture(into store: LibraryStore) async throws -> Int64 {
        let source = try await store.insertSource(
            Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                   title: "Fixture", addedAt: Date(), lastResolvedAt: nil,
                   followUpdates: false, licenseText: nil, memberCapHit: false))
        let sourceID = try XCTUnwrap(source.id)
        let artist = try await store.insertArtist(
            Artist(id: nil, name: "Nina Simone", sortName: "Nina Simone", syncID: UUID().uuidString))
        let artistID = try XCTUnwrap(artist.id)
        let album = try await store.insertAlbum(
            Album(id: nil, sourceId: sourceID, title: "Pastel Blues", artist: "Nina Simone",
                  artistId: artistID, albumArtist: "Nina Simone", genre: "Soul",
                  year: 1965, artworkId: nil))
        let albumID = try XCTUnwrap(album.id)
        let track = try await store.insertTrack(
            Track(id: nil, albumId: albumID, sourceId: sourceID, title: "Sinnerman",
                  trackNo: 1, discNo: 1, durationSec: 620,
                  codec: "FLAC", sampleRate: 44_100, bitDepthOrBitrate: "16-bit",
                  sortKey: "0001", genre: "Jazz", composer: nil, artistId: artistID))
        let trackID = try XCTUnwrap(track.id)
        _ = try await store.insertAsset(
            Asset(id: nil, trackId: trackID, kind: .localRef, bookmark: nil,
                  relPath: nil, remoteURL: "file:///Music/Hidden%20Filename.flac",
                  altRemoteURL: nil, sizeBytes: 1_024, unsupportedReason: nil))
        return trackID
    }

    private func makeV8Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(configuration: config)
        try Schema.migrator(upTo: "v8").migrate(dbQueue)
        return dbQueue
    }

    private func seedV8SearchRows(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source (id, kind, title, addedAt, followUpdates, memberCapHit,
                                        localIsFolder, syncID)
                    VALUES (1, 'local', 'Fixture', ?, 0, 0, 0, 'SRC-1')
                    """,
                arguments: [Date(timeIntervalSince1970: 1_000)])
            try db.execute(
                sql: """
                    INSERT INTO artist (id, name, sortName, syncID)
                    VALUES (1, 'Nina Simone', 'Nina Simone', 'ART-1')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO album (id, sourceId, title, artist, artistId, albumArtist,
                                       genre, year, artworkId, syncID)
                    VALUES (1, 1, 'Pastel Blues', 'Nina Simone', 1, 'Nina Simone',
                            'Soul', 1965, NULL, 'ALB-1')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO track (id, albumId, sourceId, title, trackNo, discNo, durationSec,
                                       codec, sampleRate, bitDepthOrBitrate, sortKey,
                                       genre, composer, artistId, syncID)
                    VALUES (1, 1, 1, 'Sinnerman', 1, 1, 620.0, 'FLAC', 44100, '16-bit',
                            '0001', 'Jazz', NULL, 1, 'TRK-1')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO asset (id, trackId, kind, relPath, remoteURL, altRemoteURL,
                                       opusRemoteURL, sizeBytes, unsupportedReason,
                                       syncID, needsReimport)
                    VALUES (1, 1, 'localRef', NULL, 'file:///Music/Migrated%20File.flac',
                            NULL, NULL, 1024, NULL, 'AST-1', 0)
                    """)
        }
    }

    private func matchedTrackIDs(_ db: Database, expression: String) throws -> [Int64] {
        try Int64.fetchAll(
            db,
            sql: """
                SELECT track.id FROM track
                JOIN track_fts ON track_fts.rowid = track.id
                WHERE track_fts MATCH ?
                ORDER BY track.id
                """,
            arguments: [expression])
    }
}
