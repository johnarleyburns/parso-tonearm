import Foundation
import GRDB

public enum Schema {
    private static let migrationOrder = [
        "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14",
        "v15"
    ]

    public static func migrator(upTo target: String? = nil) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        if shouldRegister("v1", upTo: target) {
            migrator.registerMigration("v1") { db in
                try db.create(table: "source") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("kind", .text).notNull()
                    t.column("iaIdentifier", .text)
                    t.column("originalURL", .text)
                    t.column("title", .text).notNull()
                    t.column("addedAt", .datetime).notNull()
                    t.column("lastResolvedAt", .datetime)
                    t.column("followUpdates", .boolean).notNull().defaults(to: false)
                    t.column("licenseText", .text)
                    t.column("memberCapHit", .boolean).notNull().defaults(to: false)
                }

                try db.create(table: "album") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("sourceId", .integer).notNull()
                        .references("source", onDelete: .cascade)
                    t.column("title", .text).notNull()
                    t.column("artist", .text)
                    t.column("year", .integer)
                    t.column("artworkId", .text)
                }

                try db.create(table: "track") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("albumId", .integer).references("album", onDelete: .setNull)
                    t.column("sourceId", .integer).notNull()
                        .references("source", onDelete: .cascade)
                    t.column("title", .text).notNull()
                    t.column("trackNo", .integer)
                    t.column("discNo", .integer)
                    t.column("durationSec", .double)
                    t.column("codec", .text)
                    t.column("sampleRate", .integer)
                    t.column("bitDepthOrBitrate", .text)
                    t.column("sortKey", .text).notNull()
                }

                try db.create(table: "asset") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("trackId", .integer).notNull()
                        .references("track", onDelete: .cascade)
                    t.column("kind", .text).notNull()
                    t.column("bookmark", .blob)
                    t.column("relPath", .text)
                    t.column("remoteURL", .text)
                    t.column("sizeBytes", .integer)
                    t.column("unsupportedReason", .text)
                }

                try db.create(table: "cache_entry") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("assetId", .integer).notNull()
                        .references("asset", onDelete: .cascade)
                    t.column("relPath", .text).notNull()
                    t.column("totalBytes", .integer)
                    t.column("byteRanges", .blob).notNull()
                    t.column("complete", .boolean).notNull().defaults(to: false)
                    t.column("lastAccessedAt", .datetime).notNull()
                    t.column("createdAt", .datetime).notNull()
                }

                try db.create(table: "playlist") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("title", .text).notNull()
                    t.column("kind", .text).notNull()
                    t.column("folderBookmark", .blob)
                    t.column("watch", .boolean).notNull().defaults(to: false)
                }

                try db.create(table: "playlist_item") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("playlistId", .integer).notNull()
                        .references("playlist", onDelete: .cascade)
                    t.column("position", .integer).notNull()
                    t.column("trackId", .integer).notNull()
                        .references("track", onDelete: .cascade)
                    t.column("sectionTitle", .text)
                }

                try db.create(virtualTable: "track_fts", using: FTS5()) { t in
                    t.synchronize(withTable: "track")
                    t.tokenizer = .unicode61()
                    t.column("title")
                }
            }
        }

        if shouldRegister("v2", upTo: target) {
            migrator.registerMigration("v2") { db in
                try db.create(table: "play_history") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("trackId", .integer).notNull()
                        .references("track", onDelete: .cascade)
                    t.column("playedAt", .datetime).notNull()
                }
                try db.create(indexOn: "play_history", columns: ["playedAt"])

                try db.create(table: "favorite") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("trackId", .integer).notNull().unique()
                        .references("track", onDelete: .cascade)
                    t.column("favoritedAt", .datetime).notNull()
                }
            }
        }

        if shouldRegister("v3", upTo: target) {
            migrator.registerMigration("v3") { db in
                try db.alter(table: "asset") { t in
                    t.add(column: "altRemoteURL", .text)
                }
                // Remove the legacy demo playlist for existing installs.
                try db.execute(
                    sql: "DELETE FROM playlist WHERE title = 'Starter Playlist' AND kind = 'manual'"
                )
            }
        }

        if shouldRegister("v4", upTo: target) {
            migrator.registerMigration("v4") { db in
                try db.alter(table: "source") { t in
                    t.add(column: "localIsFolder", .boolean).notNull().defaults(to: false)
                    t.add(column: "artworkTrackId", .integer)
                }
                // Backfill existing local sources: everything except the "Local Files"
                // bucket was created by a folder import.
                try db.execute(
                    sql: """
                        UPDATE source SET localIsFolder = 1
                        WHERE kind = 'local' AND title <> 'Local Files'
                        """)
            }
        }

        if shouldRegister("v5", upTo: target) {
            migrator.registerMigration("v5") { db in
                try db.create(table: "custom_artwork") { t in
                    t.column("trackId", .integer).notNull().unique()
                        .references("track", onDelete: .cascade)
                    t.column("artworkId", .text).notNull()
                }
            }
        }

        if shouldRegister("v6", upTo: target) {
            migrator.registerMigration("v6") { db in
                try db.alter(table: "asset") { t in
                    t.add(column: "opusRemoteURL", .text)
                }
            }
        }

        if shouldRegister("v7", upTo: target) {
            migrator.registerMigration("v7") { db in
                // Stable cross-device identity for iCloud sync (Pro). GRDB autoincrement
                // Int64 PKs aren't safe across devices; add a UUID `syncID` to every
                // synced table and backfill existing rows. Also add `needsReimport` so a
                // device with no resolvable local file can surface the track as
                // "not on this device" after a pull (local bookmarks don't sync).
                let syncedTables = [
                    "source", "album", "track", "asset", "playlist",
                    "playlist_item", "favorite", "play_history", "custom_artwork",
                ]
                for table in syncedTables {
                    try db.alter(table: table) { t in
                        t.add(column: "syncID", .text)
                    }
                    let rowIDs = try Int64.fetchAll(
                        db, sql: "SELECT rowid AS migrationRowID FROM \(table)")
                    for rowID in rowIDs {
                        try db.execute(
                            sql: "UPDATE \(table) SET syncID = ? WHERE rowid = ?",
                            arguments: [UUID().uuidString, rowID])
                    }
                    try db.create(indexOn: table, columns: ["syncID"], options: .unique)
                }
                try db.alter(table: "asset") { t in
                    t.add(column: "needsReimport", .boolean).notNull().defaults(to: false)
                }
            }
        }

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

        if shouldRegister("v15", upTo: target) {
            migrator.registerMigration("v15") { db in
                // Watch rearchitecture §8.1: the phone owns *desired download roots* and the
                // jobs that satisfy them. The v12 `watchTransfer` table cannot represent roots,
                // reference counts, retry attempts, or the watch's reported manifest, so this is
                // a fresh set of tables. The old tables stay until the Phase 6 cutover.
                try db.create(table: "watchDownloadRoot") { t in
                    t.column("rootID", .text).primaryKey()
                    t.column("kind", .text).notNull()
                    t.column("sourceID", .text).notNull()
                    t.column("title", .text).notNull().defaults(to: "")
                    t.column("desiredTrackIDs", .text).notNull()   // JSON array of watch track IDs
                    t.column("phoneRevision", .integer).notNull()
                    t.column("createdAt", .datetime).notNull()
                }
                try db.create(table: "watchDownloadJob") { t in
                    t.column("requestID", .text).primaryKey()
                    t.column("trackID", .text).notNull()
                    t.column("rootIDs", .text).notNull()           // JSON array
                    t.column("priority", .integer).notNull().defaults(to: 2)
                    t.column("state", .text).notNull()
                    t.column("failureClass", .text)
                    t.column("attempt", .integer).notNull().defaults(to: 0)
                    t.column("nextAttemptAt", .datetime)
                    t.column("expectedBytes", .integer)
                    t.column("expectedSHA256", .text)
                    t.column("errorCode", .text)
                    t.column("message", .text)
                    t.column("createdAt", .datetime).notNull()
                    t.column("updatedAt", .datetime).notNull()
                }
                try db.create(indexOn: "watchDownloadJob", columns: ["trackID"])
                try db.create(indexOn: "watchDownloadJob", columns: ["state"])
                // The watch's last reported installed truth (§1.6, second authority).
                try db.create(table: "watchDownloadManifestEntry") { t in
                    t.column("trackID", .text).primaryKey()
                    t.column("bytes", .integer).notNull()
                    t.column("manifestID", .text).notNull()
                    t.column("reportedAt", .datetime).notNull()
                }
                // Single-row monotonic revision for setDownloadRoots / removeAssets.
                try db.create(table: "watchDownloadRevision") { t in
                    t.column("id", .integer).primaryKey()
                    t.column("value", .integer).notNull()
                }
                try db.execute(sql: "INSERT INTO watchDownloadRevision (id, value) VALUES (1, 0)")
            }
        }

        return migrator
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func shouldRegister(_ migration: String, upTo target: String?) -> Bool {
        guard let target else { return true }
        guard let migrationIndex = migrationOrder.firstIndex(of: migration),
            let targetIndex = migrationOrder.firstIndex(of: target)
        else { return false }
        return migrationIndex <= targetIndex
    }
}
