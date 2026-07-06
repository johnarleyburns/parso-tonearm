import Foundation
import GRDB

enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

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

        migrator.registerMigration("v3") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "altRemoteURL", .text)
            }
            // Remove the legacy demo playlist for existing installs.
            try db.execute(sql: "DELETE FROM playlist WHERE title = 'Starter Playlist' AND kind = 'manual'")
        }

        return migrator
    }
}
