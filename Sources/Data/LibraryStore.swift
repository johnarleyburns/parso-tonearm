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

    func firstSource(title: String, kind: SourceKind) throws -> Source? {
        try dbQueue.read { db in
            try Source.filter(Column("title") == title && Column("kind") == kind.rawValue).fetchOne(db)
        }
    }

    func firstAlbum(sourceId: Int64, title: String) throws -> Album? {
        try dbQueue.read { db in
            try Album.filter(Column("sourceId") == sourceId && Column("title") == title).fetchOne(db)
        }
    }

    /// Representative per-item IA identifier for a source (first album's artworkId).
    func firstArtworkId(forSource sourceId: Int64) throws -> String? {
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
    func artworkIds(forSource sourceId: Int64, limit: Int = 40) throws -> [String] {
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

    func updateSourceTitle(id: Int64, title: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE source SET title = ? WHERE id = ?",
                           arguments: [title, id])
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

    /// Creates a manual playlist from an ordered list of track ids.
    @discardableResult
    func createManualPlaylist(title: String, trackIds: [Int64]) throws -> Playlist {
        try dbQueue.write { db in
            var pl = Playlist(id: nil, title: title, kind: .manual, folderBookmark: nil, watch: false)
            try pl.insert(db)
            guard let pid = pl.id else { return pl }
            for (i, tid) in trackIds.enumerated() {
                var item = PlaylistItem(id: nil, playlistId: pid, position: i,
                                        trackId: tid, sectionTitle: nil)
                try item.insert(db)
            }
            return pl
        }
    }

    // MARK: - Listening history (TF7)

    func recordPlay(trackId: Int64) throws {
        try dbQueue.write { db in
            var event = PlayEvent(id: nil, trackId: trackId, playedAt: Date())
            try event.insert(db)
        }
    }

    /// Distinct tracks ordered by most-recently played, capped at `limit`.
    func recentlyPlayedRows(limit: Int = 12) throws -> [TrackRow] {
        try dbQueue.read { db in
            let sql = """
            SELECT track.* FROM track
            JOIN (SELECT trackId, MAX(playedAt) AS lastPlayed
                  FROM play_history GROUP BY trackId) h
              ON h.trackId = track.id
            ORDER BY h.lastPlayed DESC
            LIMIT ?
            """
            let tracks = try Track.fetchAll(db, sql: sql, arguments: [limit])
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

    // MARK: - Favorites (TF7)

    func favoriteTrackIds() throws -> Set<Int64> {
        try dbQueue.read { db in
            let favs = try Favorite.fetchAll(db)
            return Set(favs.map { $0.trackId })
        }
    }

    func setFavorite(trackId: Int64, _ isFavorite: Bool) throws {
        try dbQueue.write { db in
            if isFavorite {
                if try Favorite.filter(Column("trackId") == trackId).fetchCount(db) == 0 {
                    var fav = Favorite(id: nil, trackId: trackId, favoritedAt: Date())
                    try fav.insert(db)
                }
            } else {
                _ = try Favorite.filter(Column("trackId") == trackId).deleteAll(db)
            }
        }
    }

    func favoriteRows() throws -> [TrackRow] {
        try dbQueue.read { db in
            // Most-recently-played first; favorites never played fall back to
            // recency of favoriting.
            let sql = """
            SELECT track.* FROM track
            JOIN favorite f ON f.trackId = track.id
            LEFT JOIN (SELECT trackId, MAX(playedAt) AS lastPlayed
                       FROM play_history GROUP BY trackId) h
              ON h.trackId = track.id
            ORDER BY COALESCE(h.lastPlayed, f.favoritedAt) DESC
            """
            let tracks = try Track.fetchAll(db, sql: sql)
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

    /// Most-recently-added library tracks (by insertion order).
    func recentlyAddedRows(limit: Int = 12) throws -> [TrackRow] {
        try dbQueue.read { db in
            let tracks = try Track.order(Column("id").desc).limit(limit).fetchAll(db)
            return try tracks.map { try self.hydrate($0, db: db) }
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
