import Foundation
import GRDB

struct TrackRow: Identifiable, Equatable {
    var track: Track
    var album: Album?
    var source: Source?
    var asset: Asset?
    var id: Int64 { track.id ?? -1 }
}

actor LibraryStore {
    static let shared = try! LibraryStore()

    let dbQueue: DatabaseQueue

    init(inMemory: Bool = false) throws {
        if inMemory {
            dbQueue = try DatabaseQueue()
        } else {
            let fm = FileManager.default
            let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
                .appendingPathComponent("Tonearm", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var config = Configuration()
            config.foreignKeysEnabled = true
            dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("library.sqlite").path,
                                        configuration: config)
        }
        try Schema.migrator().migrate(dbQueue)
    }

    // MARK: - Sources

    @discardableResult
    func insertSource(_ source: Source) throws -> Source {
        try dbQueue.write { db in
            var s = source
            try s.insert(db)
            return s
        }
    }

    func allSources() throws -> [Source] {
        try dbQueue.read { db in
            try Source.order(Column("addedAt").desc).fetchAll(db)
        }
    }

    func deleteSource(id: Int64) throws {
        _ = try dbQueue.write { db in
            try Source.deleteOne(db, key: id)
        }
    }

    func touchSourceResolved(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE source SET lastResolvedAt = ? WHERE id = ?",
                           arguments: [Date(), id])
        }
    }

    // MARK: - Albums / Tracks / Assets

    @discardableResult
    func insertAlbum(_ album: Album) throws -> Album {
        try dbQueue.write { db in
            var a = album
            try a.insert(db)
            return a
        }
    }

    @discardableResult
    func insertTrack(_ track: Track) throws -> Track {
        try dbQueue.write { db in
            var t = track
            try t.insert(db)
            return t
        }
    }

    @discardableResult
    func insertAsset(_ asset: Asset) throws -> Asset {
        try dbQueue.write { db in
            var a = asset
            try a.insert(db)
            return a
        }
    }

    func tracks(forSource sourceId: Int64) throws -> [TrackRow] {
        try dbQueue.read { db in
            let tracks = try Track.filter(Column("sourceId") == sourceId)
                .order(Column("sortKey"))
                .fetchAll(db)
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

    func allTrackRows() throws -> [TrackRow] {
        try dbQueue.read { db in
            let tracks = try Track.order(Column("sortKey")).fetchAll(db)
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

    func trackRow(id: Int64) throws -> TrackRow? {
        try dbQueue.read { db in
            guard let t = try Track.fetchOne(db, key: id) else { return nil }
            return try self.hydrate(t, db: db)
        }
    }

    private func hydrate(_ track: Track, db: Database) throws -> TrackRow {
        var album: Album?
        if let albumId = track.albumId {
            album = try Album.fetchOne(db, key: albumId)
        }
        let source = try Source.fetchOne(db, key: track.sourceId)
        let asset = try Asset.filter(Column("trackId") == track.id).fetchOne(db)
        return TrackRow(track: track, album: album, source: source, asset: asset)
    }

    // MARK: - Search (FTS5 + LIKE)

    func search(_ query: String) throws -> [TrackRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try dbQueue.read { db in
            let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed)
            var tracks: [Track] = []
            if let pattern {
                let sql = """
                SELECT track.* FROM track
                JOIN track_fts ON track_fts.rowid = track.id
                WHERE track_fts MATCH ?
                ORDER BY rank
                """
                tracks = try Track.fetchAll(db, sql: sql, arguments: [pattern])
            }
            if tracks.isEmpty {
                let like = "%\(trimmed)%"
                let sql = """
                SELECT track.* FROM track
                LEFT JOIN album ON album.id = track.albumId
                WHERE track.title LIKE ? OR album.title LIKE ? OR album.artist LIKE ?
                ORDER BY track.sortKey
                LIMIT 200
                """
                tracks = try Track.fetchAll(db, sql: sql, arguments: [like, like, like])
            }
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

    // MARK: - Playlists

    @discardableResult
    func insertPlaylist(_ playlist: Playlist) throws -> Playlist {
        try dbQueue.write { db in
            var p = playlist
            try p.insert(db)
            return p
        }
    }

    func allPlaylists() throws -> [Playlist] {
        try dbQueue.read { db in
            try Playlist.order(Column("title")).fetchAll(db)
        }
    }

    func renamePlaylist(id: Int64, title: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE playlist SET title = ? WHERE id = ?", arguments: [title, id])
        }
    }

    func deletePlaylist(id: Int64) throws {
        _ = try dbQueue.write { db in try Playlist.deleteOne(db, key: id) }
    }

    func addToPlaylist(playlistId: Int64, trackId: Int64, sectionTitle: String? = nil) throws {
        try dbQueue.write { db in
            let count = try PlaylistItem.filter(Column("playlistId") == playlistId).fetchCount(db)
            var item = PlaylistItem(id: nil, playlistId: playlistId, position: count,
                                    trackId: trackId, sectionTitle: sectionTitle)
            try item.insert(db)
        }
    }

    func playlistItems(playlistId: Int64) throws -> [TrackRow] {
        try dbQueue.read { db in
            let items = try PlaylistItem.filter(Column("playlistId") == playlistId)
                .order(Column("position")).fetchAll(db)
            return try items.compactMap { item -> TrackRow? in
                guard let t = try Track.fetchOne(db, key: item.trackId) else { return nil }
                return try self.hydrate(t, db: db)
            }
        }
    }

    // MARK: - Cache entries

    func cacheEntry(assetId: Int64) throws -> CacheEntry? {
        try dbQueue.read { db in
            try CacheEntry.filter(Column("assetId") == assetId).fetchOne(db)
        }
    }

    func upsertCacheEntry(_ entry: CacheEntry) throws {
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

    func allCacheEntries() throws -> [CacheEntry] {
        try dbQueue.read { db in try CacheEntry.fetchAll(db) }
    }

    func deleteCacheEntry(id: Int64) throws {
        _ = try dbQueue.write { db in try CacheEntry.deleteOne(db, key: id) }
    }

    func clearAllCacheEntries() throws {
        _ = try dbQueue.write { db in try CacheEntry.deleteAll(db) }
    }
}
