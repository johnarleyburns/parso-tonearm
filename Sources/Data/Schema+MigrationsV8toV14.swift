import Foundation
import GRDB

// MARK: - Migrations v8-v14

extension Schema {
    static func registerV8toV14(_ migrator: inout DatabaseMigrator, upTo target: String?) {
        if shouldRegister("v8", upTo: target) {
            migrator.registerMigration("v8") { db in
                try db.create(table: "artist") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("name", .text).notNull()
                    t.column("sortName", .text).notNull()
                    t.column("syncID", .text)
                }
                try db.execute(
                    sql: "CREATE UNIQUE INDEX artist_name_nocase_idx ON artist(name COLLATE NOCASE)"
                )
                try db.create(indexOn: "artist", columns: ["sortName"])
                try db.create(indexOn: "artist", columns: ["syncID"], options: .unique)

                try db.alter(table: "album") { t in
                    t.add(column: "artistId", .integer).references("artist", onDelete: .setNull)
                    t.add(column: "albumArtist", .text)
                    t.add(column: "genre", .text)
                }
                try db.alter(table: "track") { t in
                    t.add(column: "genre", .text)
                    t.add(column: "composer", .text)
                    t.add(column: "artistId", .integer).references("artist", onDelete: .setNull)
                }
                try db.create(indexOn: "album", columns: ["artistId"])
                try db.create(indexOn: "track", columns: ["artistId"])
                try db.create(indexOn: "album", columns: ["genre"])
                try db.create(indexOn: "track", columns: ["genre"])

                let albumRows = try Row.fetchAll(
                    db, sql: "SELECT id, artist FROM album ORDER BY id")
                var artistIDsByKey: [String: Int64] = [:]

                func artistID(for name: String) throws -> Int64 {
                    let normalized = ArtistNamePolicy.normalize(name) ?? name
                    let key = ArtistNamePolicy.identityKey(for: normalized)
                    if let existing = artistIDsByKey[key] { return existing }
                    if let row = try Row.fetchOne(
                        db,
                        sql: "SELECT id FROM artist WHERE name = ? COLLATE NOCASE",
                        arguments: [normalized]
                    ) {
                        let id: Int64 = row["id"]
                        artistIDsByKey[key] = id
                        return id
                    }

                    try db.execute(
                        sql: "INSERT INTO artist (name, sortName, syncID) VALUES (?, ?, ?)",
                        arguments: [
                            normalized,
                            ArtistNamePolicy.sortName(for: normalized),
                            UUID().uuidString,
                        ]
                    )
                    let id = db.lastInsertedRowID
                    artistIDsByKey[key] = id
                    return id
                }

                for row in albumRows {
                    let albumID: Int64 = row["id"]
                    let legacyArtist: String? = row["artist"]
                    let albumArtist = ArtistNamePolicy.normalize(legacyArtist)
                    if let albumArtist {
                        try db.execute(
                            sql: "UPDATE album SET albumArtist = ? WHERE id = ?",
                            arguments: [albumArtist, albumID]
                        )
                    }

                    let artistNames = ArtistNamePolicy.artistNames(from: legacyArtist)
                    guard let primary = artistNames.first else { continue }
                    for name in artistNames {
                        _ = try artistID(for: name)
                    }
                    let primaryID = try artistID(for: primary)
                    try db.execute(
                        sql: "UPDATE album SET artistId = ? WHERE id = ?",
                        arguments: [primaryID, albumID]
                    )
                    try db.execute(
                        sql: "UPDATE track SET artistId = ? WHERE albumId = ? AND artistId IS NULL",
                        arguments: [primaryID, albumID]
                    )
                }
            }
        }

        if shouldRegister("v9", upTo: target) {
            migrator.registerMigration("v9") { db in
                let triggers = try String.fetchAll(
                    db,
                    sql: """
                        SELECT name FROM sqlite_master
                        WHERE type = 'trigger' AND sql LIKE '%track_fts%'
                        """)
                for trigger in triggers {
                    try db.execute(sql: "DROP TRIGGER IF EXISTS \(quotedIdentifier(trigger))")
                }
                try db.execute(sql: "DROP TABLE IF EXISTS track_fts")
                try db.create(virtualTable: "track_fts", using: FTS5()) { t in
                    t.tokenizer = .unicode61()
                    t.column("title")
                    t.column("artist")
                    t.column("album")
                    t.column("genre")
                    t.column("filename")
                }
                try db.execute(sql: """
                    INSERT INTO track_fts(rowid, title, artist, album, genre, filename)
                    SELECT track.id,
                           track.title,
                           COALESCE(track_artist.name, album.albumArtist, album.artist, album_artist.name, ''),
                           COALESCE(album.title, ''),
                           TRIM(COALESCE(track.genre, '') || ' ' || COALESCE(album.genre, '')),
                           COALESCE(asset_search.filename, '')
                    FROM track
                    LEFT JOIN album ON album.id = track.albumId
                    LEFT JOIN artist track_artist ON track_artist.id = track.artistId
                    LEFT JOIN artist album_artist ON album_artist.id = album.artistId
                    LEFT JOIN (
                        SELECT trackId,
                               MIN(COALESCE(NULLIF(relPath, ''),
                                            NULLIF(remoteURL, ''),
                                            NULLIF(altRemoteURL, ''),
                                            '')) AS filename
                        FROM asset
                        GROUP BY trackId
                    ) asset_search ON asset_search.trackId = track.id
                    WHERE track.id IS NOT NULL
                    """)
            }
        }

        if shouldRegister("v10", upTo: target) {
            migrator.registerMigration("v10") { db in
                try db.alter(table: "track") { t in
                    t.add(column: "rgTrackGain", .double)
                    t.add(column: "rgAlbumGain", .double)
                    t.add(column: "rgTrackPeak", .double)
                    t.add(column: "rgAlbumPeak", .double)
                }
            }
        }

        if shouldRegister("v11", upTo: target) {
            migrator.registerMigration("v11") { _ in
                // SourceKind's remote provider cases are persisted in the existing
                // source.kind text column; v11 records that model boundary.
            }
        }

        if shouldRegister("v12", upTo: target) {
            migrator.registerMigration("v12") { db in
                try db.create(table: "watchTransfer") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("trackId", .integer).notNull().unique().references("track", onDelete: .cascade)
                    t.column("state", .text).notNull()
                    t.column("originKind", .text).notNull()
                    t.column("originId", .integer)
                    t.column("bytes", .integer)
                    t.column("errorText", .text)
                    t.column("queuedAt", .datetime).notNull()
                    t.column("updatedAt", .datetime).notNull()
                }
                try db.create(table: "watchManifest") { t in
                    t.column("trackKey", .text).primaryKey()
                    t.column("bytes", .integer).notNull()
                    t.column("pinned", .boolean).notNull()
                    t.column("reportedAt", .datetime).notNull()
                }
            }
        }

        if shouldRegister("v13", upTo: target) {
            migrator.registerMigration("v13") { db in
                try db.alter(table: "playlist") { t in
                    t.add(column: "sourceId", .integer).references("source", onDelete: .setNull)
                }

                // Older folder playlists were linked to their source by title.
                // Assign each legacy row to a distinct matching folder source in
                // insertion order, which preserves same-named folders instead of
                // collapsing them together.
                let sources = try Row.fetchAll(db, sql: """
                    SELECT id, title FROM source
                    WHERE kind = 'local' AND localIsFolder = 1
                    ORDER BY id
                    """)
                for source in sources {
                    let sourceID: Int64 = source["id"]
                    let title: String = source["title"]
                    let candidates = try Row.fetchAll(db, sql: """
                        SELECT id FROM playlist
                        WHERE kind = 'folder' AND sourceId IS NULL AND title = ?
                        ORDER BY id
                        """, arguments: [title])
                    guard let candidate = candidates.first else { continue }
                    let playlistID: Int64 = candidate["id"]
                    try db.execute(sql: "UPDATE playlist SET sourceId = ? WHERE id = ?",
                                   arguments: [sourceID, playlistID])
                }

                // If a pre-release database already contains source-linked
                // duplicates, merge their items into the oldest row before
                // removing the duplicate. Positions are appended, so no
                // playlist membership is lost.
                let duplicateGroups = try Row.fetchAll(db, sql: """
                    SELECT sourceId, MIN(id) AS keepID
                    FROM playlist
                    WHERE kind = 'folder' AND sourceId IS NOT NULL
                    GROUP BY sourceId HAVING COUNT(*) > 1
                    """)
                for group in duplicateGroups {
                    let sourceID: Int64 = group["sourceId"]
                    let keepID: Int64 = group["keepID"]
                    let duplicates = try Int64.fetchAll(db, sql: """
                        SELECT id FROM playlist
                        WHERE kind = 'folder' AND sourceId = ? AND id <> ?
                        ORDER BY id
                        """, arguments: [sourceID, keepID])
                    var nextPosition = (try Int.fetchOne(db, sql: """
                        SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_item WHERE playlistId = ?
                        """, arguments: [keepID])) ?? 0
                    for duplicateID in duplicates {
                        let items = try Row.fetchAll(db, sql: """
                            SELECT trackId, sectionTitle FROM playlist_item
                            WHERE playlistId = ? ORDER BY position, id
                            """, arguments: [duplicateID])
                        for item in items {
                            try db.execute(sql: """
                                INSERT INTO playlist_item (playlistId, position, trackId, sectionTitle)
                                VALUES (?, ?, ?, ?)
                                """, arguments: [keepID, nextPosition, item["trackId"], item["sectionTitle"]])
                            nextPosition += 1
                        }
                        try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [duplicateID])
                    }
                }
                try db.create(indexOn: "playlist", columns: ["sourceId"])
            }
        }

        if shouldRegister("v14", upTo: target) {
            migrator.registerMigration("v14") { db in
                try db.alter(table: "source") { $0.add(column: "folderPath", .text) }
                try db.create(indexOn: "source", columns: ["folderPath"])
            }
        }
    }

    fileprivate static func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
