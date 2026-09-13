import Foundation
import GRDB

/// Album/track/asset ingestion and lookup, plus full-text search — split
/// out of `LibraryStore.swift` (pure reorganization). The shared hydration
/// and search-index helpers (`hydrate`, `artistID`, `refreshSearchIndex`,
/// `searchFilename`) stay in the primary file since other extensions use them
/// too.
extension LibraryStore {

    // MARK: - Albums / Tracks / Assets

    @discardableResult
    public func insertAlbum(_ album: Album) throws -> Album {
        try dbQueue.write { db in
            var a = album
            try a.insert(db)
            return a
        }
    }

    @discardableResult
    public func insertArtist(_ artist: Artist) throws -> Artist {
        try dbQueue.write { db in
            var a = artist
            try a.insert(db)
            return a
        }
    }

    public func allArtists() throws -> [Artist] {
        try dbQueue.read { db in
            try Artist.order(Column("sortName"), Column("name")).fetchAll(db)
        }
    }

    public func albums(forArtist artistName: String) throws -> [Album] {
        try dbQueue.read { db in
            try Album.fetchAll(db, sql: """
                SELECT album.* FROM album
                LEFT JOIN artist ON artist.id = album.artistId
                WHERE album.albumArtist = ? COLLATE NOCASE
                   OR album.artist = ? COLLATE NOCASE
                   OR artist.name = ? COLLATE NOCASE
                ORDER BY album.title COLLATE NOCASE, album.year
                """, arguments: [artistName, artistName, artistName])
        }
    }

    public func tracks(forArtist artistName: String) throws -> [TrackRow] {
        try dbQueue.read { db in
            let tracks = try Track.fetchAll(db, sql: """
                SELECT track.* FROM track
                LEFT JOIN album ON album.id = track.albumId
                LEFT JOIN artist track_artist ON track_artist.id = track.artistId
                LEFT JOIN artist album_artist ON album_artist.id = album.artistId
                WHERE album.albumArtist = ? COLLATE NOCASE
                   OR album.artist = ? COLLATE NOCASE
                   OR track_artist.name = ? COLLATE NOCASE
                   OR album_artist.name = ? COLLATE NOCASE
                ORDER BY track.sortKey
                """, arguments: [artistName, artistName, artistName, artistName])
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

    public func allGenres() throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT genre FROM (
                    SELECT genre FROM album WHERE genre IS NOT NULL AND TRIM(genre) <> ''
                    UNION
                    SELECT genre FROM track WHERE genre IS NOT NULL AND TRIM(genre) <> ''
                )
                ORDER BY genre COLLATE NOCASE
                """)
            return rows.compactMap { row in
                let value: String? = row["genre"]
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
        }
    }

    public func findOrCreateArtist(name: String, sortName: String) throws -> Artist {
        try dbQueue.write { db in
            if let existing = try Artist.fetchOne(
                db,
                sql: "SELECT * FROM artist WHERE name = ? COLLATE NOCASE",
                arguments: [name])
            {
                return existing
            }
            var artist = Artist(id: nil, name: name, sortName: sortName, syncID: UUID().uuidString)
            try artist.insert(db)
            return artist
        }
    }

    public func fillAlbumMetadataIfEmpty(
        id: Int64,
        artistId: Int64?,
        albumArtist: String?,
        genre: String?,
        year: Int?
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE album
                    SET artistId = COALESCE(artistId, ?),
                        artist = COALESCE(artist, ?),
                        albumArtist = COALESCE(albumArtist, ?),
                        genre = COALESCE(genre, ?),
                        year = COALESCE(year, ?)
                    WHERE id = ?
                    """,
                arguments: [artistId, albumArtist, albumArtist, genre, year, id])
            let trackIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM track WHERE albumId = ?",
                arguments: [id])
            for trackID in trackIDs {
                try self.refreshSearchIndex(trackID: trackID, db: db)
            }
        }
    }

    @discardableResult
    public func insertTrack(_ track: Track) throws -> Track {
        try dbQueue.write { db in
            var t = track
            try t.insert(db)
            try self.refreshSearchIndex(trackID: t.id, db: db)
            return t
        }
    }

    @discardableResult
    public func insertAsset(_ asset: Asset) throws -> Asset {
        try dbQueue.write { db in
            var a = asset
            try a.insert(db)
            try self.refreshSearchIndex(trackID: a.trackId, db: db)
            return a
        }
    }

    public func tracks(forSource sourceId: Int64) throws -> [TrackRow] {
        try dbQueue.read { db in
            let tracks = try Track.filter(Column("sourceId") == sourceId)
                .order(Column("sortKey"))
                .fetchAll(db)
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

    public func allTrackRows() throws -> [TrackRow] {
        try dbQueue.read { db in
            let tracks = try Track.order(Column("sortKey")).fetchAll(db)
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

    public func smartPlaylistRows(_ playlist: SmartPlaylist) throws -> [TrackRow] {
        let query = playlist.compiledQuery()
        return try dbQueue.read { db in
            let tracks = try Track.fetchAll(db, sql: query.sql, arguments: query.arguments)
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

    @discardableResult
    public func applyTagEditPlan(_ plan: TagEdit.Plan) throws -> Int {
        guard plan.canApply else { return 0 }
        return try dbQueue.write { db in
            var applied = 0
            for operation in plan.operations {
                guard var track = try Track.fetchOne(db, key: operation.trackID) else { continue }
                var album = try track.albumId.flatMap { try Album.fetchOne(db, key: $0) }
                var changed = false
                var albumChanged = false

                for change in operation.changes {
                    switch change.field {
                    case .title:
                        if let value = change.after?.textValue {
                            track.title = value
                            changed = true
                        }
                    case .artist:
                        if let value = change.after?.textValue {
                            track.artistId = try self.artistID(for: value, db: db)
                        } else {
                            track.artistId = nil
                        }
                        changed = true
                    case .albumTitle:
                        if album != nil {
                            album?.title = change.after?.textValue ?? ""
                            albumChanged = true
                        }
                    case .albumArtist:
                        if album != nil {
                            album?.albumArtist = change.after?.textValue
                            album?.artist = change.after?.textValue
                            album?.artistId = try change.after?.textValue.flatMap { try self.artistID(for: $0, db: db) }
                            albumChanged = true
                        }
                    case .genre:
                        track.genre = change.after?.textValue
                        changed = true
                    case .composer:
                        track.composer = change.after?.textValue
                        changed = true
                    case .trackNumber:
                        track.trackNo = change.after?.integerValue
                        if let trackNo = track.trackNo {
                            track.sortKey = String(format: "%04d", trackNo)
                        }
                        changed = true
                    case .discNumber:
                        track.discNo = change.after?.integerValue
                        changed = true
                    case .year:
                        if album != nil {
                            album?.year = change.after?.integerValue
                            albumChanged = true
                        }
                    }
                }

                if changed {
                    try track.update(db)
                }
                if albumChanged, let album {
                    try album.update(db)
                }
                if changed || albumChanged {
                    try self.refreshSearchIndex(trackID: track.id, db: db)
                    applied += 1
                }
            }
            return applied
        }
    }

    public func trackRow(id: Int64) throws -> TrackRow? {
        try dbQueue.read { db in
            guard let t = try Track.fetchOne(db, key: id) else { return nil }
            return try self.hydrate(t, db: db)
        }
    }

    /// Resolves a track by its stable `syncID` (used after reinstall+CloudKit
    /// resync when rowids have changed — G6).
    public func trackRow(syncID: String) throws -> TrackRow? {
        try dbQueue.read { db in
            guard let t = try Track.filter(Column("syncID") == syncID).fetchOne(db) else {
                return nil
            }
            return try self.hydrate(t, db: db)
        }
    }

    // MARK: - Search (FTS5)

    public func search(_ query: String) throws -> [TrackRow] {
        guard let expression = SearchQueryBuilder.matchExpression(for: query) else { return [] }
        return try dbQueue.read { db in
            let sql = """
            SELECT track.* FROM track
            JOIN track_fts ON track_fts.rowid = track.id
            WHERE track_fts MATCH ?
            ORDER BY rank, track.sortKey
            LIMIT 200
            """
            let tracks = try Track.fetchAll(db, sql: sql, arguments: [expression])
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

}
