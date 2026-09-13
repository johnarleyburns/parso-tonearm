import Foundation
import GRDB

/// Cache entries, the full sync snapshot reads (iCloud, Pro), and the
/// single-row deletes/updates/syncID lookups they rely on — split out of
/// `LibraryStore.swift` (pure reorganization).
extension LibraryStore {

    // MARK: - Cache entries

    public func cacheEntry(assetId: Int64) throws -> CacheEntry? {
        try dbQueue.read { db in
            try CacheEntry.filter(Column("assetId") == assetId).fetchOne(db)
        }
    }

    public func upsertCacheEntry(_ entry: CacheEntry) throws {
        try dbQueue.write { db in
            var e = entry
            if let existing = try CacheEntry.filter(Column("assetId") == entry.assetId).fetchOne(db) {
                e.id = existing.id
                try e.update(db)
            } else {
                try e.insert(db)
            }
        }
    }

    public func allCacheEntries() throws -> [CacheEntry] {
        try dbQueue.read { db in try CacheEntry.fetchAll(db) }
    }

    public func deleteCacheEntry(id: Int64) throws {
        _ = try dbQueue.write { db in try CacheEntry.deleteOne(db, key: id) }
    }

    public func clearAllCacheEntries() throws {
        _ = try dbQueue.write { db in try CacheEntry.deleteAll(db) }
    }

    // MARK: - Sync snapshot (iCloud, Pro)

    /// All rows of every synced table, for a full push snapshot. Raw domain
    /// values carry their `syncID`; parent references are resolved via the
    /// `syncID` lookups below so cross-device identity is stable (C2/C3).
    public func allAlbums() throws -> [Album] {
        try dbQueue.read { db in try Album.fetchAll(db) }
    }

    public func allTracks() throws -> [Track] {
        try dbQueue.read { db in try Track.fetchAll(db) }
    }

    public func allAssets() throws -> [Asset] {
        try dbQueue.read { db in try Asset.fetchAll(db) }
    }

    public func allPlaylistItems() throws -> [PlaylistItem] {
        try dbQueue.read { db in try PlaylistItem.fetchAll(db) }
    }

    public func allFavorites() throws -> [Favorite] {
        try dbQueue.read { db in try Favorite.fetchAll(db) }
    }

    public func allPlayEvents() throws -> [PlayEvent] {
        try dbQueue.read { db in try PlayEvent.fetchAll(db) }
    }

    public func allCustomArtworkRecords() throws -> [CustomArtworkRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT syncID, artworkId FROM custom_artwork WHERE syncID IS NOT NULL")
            return rows.compactMap { row in
                guard let syncID: String = row["syncID"], let artworkId: String = row["artworkId"] else { return nil }
                return CustomArtworkRecord(syncID: syncID, artworkId: artworkId)
            }
        }
    }

    /// Looks up a table's `syncID` for a given local `Int64` PK (parent ref).
    public func syncID(table: String, id: Int64) throws -> String? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT syncID FROM \(table) WHERE id = ?",
                             arguments: [id])?["syncID"]
        }
    }

    /// Resolves a `syncID` back to a local `Int64` PK (used to re-link pulled rows).
    public func localID(table: String, syncID: String) throws -> Int64? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT id FROM \(table) WHERE syncID = ?",
                             arguments: [syncID])?["id"]
        }
    }

    // MARK: - Deletes

    public func deleteTrack(id: Int64) throws {
        _ = try dbQueue.write { db in try Track.deleteOne(db, key: id) }
    }

    public func deleteAlbum(id: Int64) throws {
        _ = try dbQueue.write { db in try Album.deleteOne(db, key: id) }
    }

    public func deleteArtist(id: Int64) throws {
        _ = try dbQueue.write { db in try Artist.deleteOne(db, key: id) }
    }

    // MARK: - Updates (single-row)

    @discardableResult
    public func updateTrack(_ track: Track) throws -> Track {
        try dbQueue.write { db in
            try track.update(db)
            return track
        }
    }

    @discardableResult
    public func updateAlbum(_ album: Album) throws -> Album {
        try dbQueue.write { db in
            try album.update(db)
            return album
        }
    }

    // MARK: - SyncID lookup

    public func trackBySyncID(_ syncID: String) throws -> Track? {
        try dbQueue.read { db in
            try Track.filter(Column("syncID") == syncID).fetchOne(db)
        }
    }

    public func albumByTitle(_ title: String, sourceId: Int64) throws -> Album? {
        try dbQueue.read { db in
            try Album.filter(Column("title") == title && Column("sourceId") == sourceId).fetchOne(db)
        }
    }
}
