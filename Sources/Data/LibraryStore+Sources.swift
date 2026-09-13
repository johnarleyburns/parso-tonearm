import Foundation
import GRDB

/// Source-level and per-item custom-artwork queries, split out of
/// `LibraryStore.swift` (a pure reorganization, same file-per-concern
/// convention used elsewhere in this codebase).
extension LibraryStore {

    // MARK: - Sources

    @discardableResult
    public func insertSource(_ source: Source) throws -> Source {
        try dbQueue.write { db in
            var s = source
            try s.insert(db)
            return s
        }
    }

    public func allSources() throws -> [Source] {
        try dbQueue.read { db in
            try Source.order(Column("addedAt").desc).fetchAll(db)
        }
    }

    public func firstSource(title: String, kind: SourceKind) throws -> Source? {
        try dbQueue.read { db in
            try Source.filter(Column("title") == title && Column("kind") == kind.rawValue).fetchOne(db)
        }
    }

    public func folderSource(path: String) throws -> Source? {
        try dbQueue.read { db in
            try Source.filter(Column("kind") == SourceKind.local.rawValue
                              && Column("folderPath") == path).fetchOne(db)
        }
    }

    public func firstAlbum(sourceId: Int64, title: String) throws -> Album? {
        try dbQueue.read { db in
            try Album.filter(Column("sourceId") == sourceId && Column("title") == title).fetchOne(db)
        }
    }

    /// First album belonging to a source (by insertion order). Used by folder-watch
    /// rescans to append new tracks into the folder's existing album.
    public func firstAlbumForSource(_ sourceId: Int64) throws -> Album? {
        try dbQueue.read { db in
            try Album.filter(Column("sourceId") == sourceId).order(Column("id")).fetchOne(db)
        }
    }

    /// The folder playlist explicitly owned by a source.
    public func folderPlaylist(matchingSourceId sourceId: Int64) throws -> Playlist? {
        try dbQueue.read { db in
            return try Playlist
                .filter(Column("sourceId") == sourceId && Column("kind") == PlaylistKind.folder.rawValue)
                .order(Column("id"))
                .fetchOne(db)
        }
    }

    /// Representative per-item IA identifier for a source (first album's artworkId).
    public func firstArtworkId(forSource sourceId: Int64) throws -> String? {
        try dbQueue.read { db in
            let album = try Album.filter(Column("sourceId") == sourceId)
                .order(Column("id"))
                .fetchOne(db)
            guard let artworkId = album?.artworkId, !artworkId.isEmpty else { return nil }
            return artworkId
        }
    }

    /// Candidate per-item IA identifiers for a source, in album order. Used to
    /// pick a representative cover that isn't an IA placeholder.
    public func artworkIds(forSource sourceId: Int64, limit: Int = 40) throws -> [String] {
        try dbQueue.read { db in
            let albums = try Album.filter(Column("sourceId") == sourceId)
                .order(Column("id"))
                .fetchAll(db)
            return albums.compactMap { album -> String? in
                guard let id = album.artworkId, !id.isEmpty else { return nil }
                return id
            }.prefix(limit).map { $0 }
        }
    }

    public func deleteSource(id: Int64) throws {
        _ = try dbQueue.write { db in
            try Source.deleteOne(db, key: id)
        }
    }

    // MARK: - Custom Artwork

    public func customArtworkId(for trackId: Int64) throws -> String? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT artworkId FROM custom_artwork WHERE trackId = ?",
                             arguments: [trackId])?["artworkId"]
        }
    }

    public func setCustomArtwork(trackId: Int64, artworkId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO custom_artwork (trackId, artworkId) VALUES (?, ?)
                ON CONFLICT(trackId) DO UPDATE SET artworkId = excluded.artworkId
                """, arguments: [trackId, artworkId])
        }
    }

    public func deleteCustomArtwork(trackId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM custom_artwork WHERE trackId = ?",
                           arguments: [trackId])
        }
    }

    /// All custom artwork IDs for a source (used to delete files before the
    /// source cascade removes the DB rows).
    public func customArtworkIds(forSource sourceId: Int64) throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ca.artworkId FROM custom_artwork ca
                JOIN track t ON t.id = ca.trackId
                WHERE t.sourceId = ?
                """, arguments: [sourceId])
            return rows.compactMap { $0["artworkId"] }
        }
    }

    public func allCustomArtworkIds() throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT artworkId FROM custom_artwork")
            return rows.compactMap { $0["artworkId"] }
        }
    }

    public func clearAllCustomArtwork() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM custom_artwork")
        }
    }

    // MARK: - Custom Artwork (album-level)

    public func albumCustomArtworkId(for albumId: Int64) throws -> String? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT artworkId FROM custom_artwork_album WHERE albumId = ?",
                             arguments: [albumId])?["artworkId"]
        }
    }

    public func setAlbumCustomArtwork(albumId: Int64, artworkId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO custom_artwork_album (albumId, artworkId) VALUES (?, ?)
                ON CONFLICT(albumId) DO UPDATE SET artworkId = excluded.artworkId
                """, arguments: [albumId, artworkId])
        }
    }

    public func deleteAlbumCustomArtwork(albumId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM custom_artwork_album WHERE albumId = ?",
                           arguments: [albumId])
        }
    }

    public func allAlbumCustomArtworkIds() throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT artworkId FROM custom_artwork_album")
            return rows.compactMap { $0["artworkId"] }
        }
    }

    public func clearAllAlbumCustomArtwork() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM custom_artwork_album")
        }
    }

    // MARK: - Custom Artwork (source-level)

    public func sourceCustomArtworkId(for sourceId: Int64) throws -> String? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT artworkId FROM custom_artwork_source WHERE sourceId = ?",
                             arguments: [sourceId])?["artworkId"]
        }
    }

    public func setSourceCustomArtwork(sourceId: Int64, artworkId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO custom_artwork_source (sourceId, artworkId) VALUES (?, ?)
                ON CONFLICT(sourceId) DO UPDATE SET artworkId = excluded.artworkId
                """, arguments: [sourceId, artworkId])
        }
    }

    public func deleteSourceCustomArtwork(sourceId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM custom_artwork_source WHERE sourceId = ?",
                           arguments: [sourceId])
        }
    }

    public func allSourceCustomArtworkIds() throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT artworkId FROM custom_artwork_source")
            return rows.compactMap { $0["artworkId"] }
        }
    }

    public func clearAllSourceCustomArtwork() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM custom_artwork_source")
        }
    }

    public func touchSourceResolved(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE source SET lastResolvedAt = ? WHERE id = ?",
                           arguments: [Date(), id])
        }
    }

    public func updateSourceTitle(id: Int64, title: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE source SET title = ? WHERE id = ?",
                           arguments: [title, id])
        }
    }

    /// Persists which track's embedded artwork represents a source, so the
    /// chosen cover is remembered across launches.
    public func setSourceArtworkTrack(id: Int64, trackId: Int64?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE source SET artworkTrackId = ? WHERE id = ?",
                           arguments: [trackId, id])
        }
    }

    /// First track (by sort order) of a source, hydrated with album/asset.
    public func firstTrackRow(forSource sourceId: Int64) throws -> TrackRow? {
        try dbQueue.read { db in
            guard let track = try Track.filter(Column("sourceId") == sourceId)
                .order(Column("sortKey")).fetchOne(db) else { return nil }
            return try self.hydrate(track, db: db)
        }
    }

}
