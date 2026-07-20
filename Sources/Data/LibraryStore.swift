import Foundation
import GRDB

public struct TrackRow: Identifiable, Equatable {
    public var track: Track
    public var album: Album?
    public var source: Source?
    public var asset: Asset?
    public var artist: Artist? = nil
    public var id: Int64 { track.id ?? -1 }

    public init(track: Track,
                album: Album?,
                source: Source?,
                asset: Asset?,
                artist: Artist? = nil) {
        self.track = track
        self.album = album
        self.source = source
        self.asset = asset
        self.artist = artist
    }
}

public struct PlaylistTrackRow: Identifiable, Equatable {
    public var item: PlaylistItem
    public var row: TrackRow
    public var id: Int64 { item.id ?? -1 }

    public init(item: PlaylistItem, row: TrackRow) {
        self.item = item
        self.row = row
    }
}

public actor LibraryStore {
    public static let shared = try! LibraryStore()

    public let dbQueue: DatabaseQueue

    public init(inMemory: Bool = false) throws {
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

    /// The folder playlist whose title matches a source's title, if any. Folder
    /// imports create both a `.local` source and a `.folder` playlist sharing the
    /// folder name; this reconnects them for watch rescans.
    public func folderPlaylist(matchingSourceId sourceId: Int64) throws -> Playlist? {
        try dbQueue.read { db in
            guard let source = try Source.fetchOne(db, key: sourceId) else { return nil }
            return try Playlist
                .filter(Column("title") == source.title && Column("kind") == PlaylistKind.folder.rawValue)
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

    private func hydrate(_ track: Track, db: Database) throws -> TrackRow {
        var album: Album?
        if let albumId = track.albumId {
            album = try Album.fetchOne(db, key: albumId)
        }
        var artist: Artist?
        if let artistId = track.artistId {
            artist = try Artist.fetchOne(db, key: artistId)
        }
        let source = try Source.fetchOne(db, key: track.sourceId)
        let asset = try Asset.filter(Column("trackId") == track.id).fetchOne(db)
        return TrackRow(track: track, album: album, source: source, asset: asset, artist: artist)
    }

    private func artistID(for rawName: String, db: Database) throws -> Int64? {
        guard let name = ArtistNamePolicy.normalize(rawName) else { return nil }
        if let existing = try Artist.fetchOne(
            db,
            sql: "SELECT * FROM artist WHERE name = ? COLLATE NOCASE",
            arguments: [name]
        ) {
            return existing.id
        }
        var artist = Artist(
            id: nil,
            name: name,
            sortName: ArtistNamePolicy.sortName(for: name),
            syncID: UUID().uuidString
        )
        try artist.insert(db)
        return artist.id
    }

    private func refreshSearchIndex(trackID: Int64?, db: Database) throws {
        guard let trackID else { return }
        try db.execute(sql: "DELETE FROM track_fts WHERE rowid = ?", arguments: [trackID])
        guard let row = try Row.fetchOne(db, sql: """
            SELECT track.title AS title,
                   COALESCE(track_artist.name, album.albumArtist, album.artist, album_artist.name, '') AS artist,
                   COALESCE(album.title, '') AS album,
                   COALESCE(track.genre, '') AS trackGenre,
                   COALESCE(album.genre, '') AS albumGenre,
                   asset.relPath AS relPath,
                   asset.remoteURL AS remoteURL,
                   asset.altRemoteURL AS altRemoteURL
            FROM track
            LEFT JOIN album ON album.id = track.albumId
            LEFT JOIN artist track_artist ON track_artist.id = track.artistId
            LEFT JOIN artist album_artist ON album_artist.id = album.artistId
            LEFT JOIN asset ON asset.trackId = track.id
            WHERE track.id = ?
            ORDER BY asset.id
            LIMIT 1
            """, arguments: [trackID]) else { return }

        let title: String = row["title"]
        let artist: String = row["artist"]
        let album: String = row["album"]
        let trackGenre: String = row["trackGenre"]
        let albumGenre: String = row["albumGenre"]
        let genre = [trackGenre, albumGenre]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let filename = searchFilename(
            relPath: row["relPath"],
            remoteURL: row["remoteURL"],
            altRemoteURL: row["altRemoteURL"])

        try db.execute(sql: """
            INSERT INTO track_fts(rowid, title, artist, album, genre, filename)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [trackID, title, artist, album, genre, filename])
    }

    private func searchFilename(relPath: String?, remoteURL: String?, altRemoteURL: String?) -> String {
        for value in [relPath, remoteURL, altRemoteURL] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            if let url = URL(string: trimmed), !url.lastPathComponent.isEmpty {
                return url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            }
            let filename = URL(fileURLWithPath: trimmed).lastPathComponent
            if !filename.isEmpty { return filename }
        }
        return ""
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

    // MARK: - Playlists

    @discardableResult
    public func insertPlaylist(_ playlist: Playlist) throws -> Playlist {
        try dbQueue.write { db in
            var p = playlist
            try p.insert(db)
            return p
        }
    }

    public func allPlaylists() throws -> [Playlist] {
        try dbQueue.read { db in
            try Playlist.order(Column("title")).fetchAll(db)
        }
    }

    public func renamePlaylist(id: Int64, title: String) throws {
        try dbQueue.write { db in
            let existing = try Playlist.fetchOne(db, key: id)
            try db.execute(sql: "UPDATE playlist SET title = ? WHERE id = ?", arguments: [title, id])
            if existing?.kind == .folder, let oldTitle = existing?.title {
                try db.execute(
                    sql: """
                        UPDATE source SET title = ?
                        WHERE kind = ? AND title = ?
                        """,
                    arguments: [title, SourceKind.local.rawValue, oldTitle])
            }
        }
    }

    public func deletePlaylist(id: Int64) throws {
        _ = try dbQueue.write { db in try Playlist.deleteOne(db, key: id) }
    }

    public func addToPlaylist(playlistId: Int64, trackId: Int64, sectionTitle: String? = nil) throws {
        try dbQueue.write { db in
            let count = try PlaylistItem.filter(Column("playlistId") == playlistId).fetchCount(db)
            var item = PlaylistItem(id: nil, playlistId: playlistId, position: count,
                                    trackId: trackId, sectionTitle: sectionTitle)
            try item.insert(db)
        }
    }

    public func playlistItems(playlistId: Int64) throws -> [TrackRow] {
        try playlistTrackRows(playlistId: playlistId).map(\.row)
    }

    public func playlistTrackRows(playlistId: Int64) throws -> [PlaylistTrackRow] {
        try dbQueue.read { db in
            let items = try playlistItemRecords(playlistId: playlistId, db: db)
            return try items.compactMap { item -> PlaylistTrackRow? in
                guard let t = try Track.fetchOne(db, key: item.trackId) else { return nil }
                return try PlaylistTrackRow(item: item, row: self.hydrate(t, db: db))
            }
        }
    }

    public func reorderPlaylist(id playlistId: Int64, from source: Int, to destination: Int) throws {
        try dbQueue.write { db in
            let original = try playlistItemRecords(playlistId: playlistId, db: db)
            let edited = PlaylistEditor.move(original, from: source, to: destination)
            try self.persistPlaylistItems(original: original, edited: edited, db: db)
        }
    }

    public func reorderPlaylist(id playlistId: Int64, fromOffsets offsets: IndexSet, toOffset destination: Int) throws {
        try dbQueue.write { db in
            let original = try playlistItemRecords(playlistId: playlistId, db: db)
            let edited = PlaylistEditor.move(original, fromOffsets: offsets, toOffset: destination)
            try self.persistPlaylistItems(original: original, edited: edited, db: db)
        }
    }

    public func removeFromPlaylist(playlistId: Int64, at index: Int) throws {
        try dbQueue.write { db in
            let original = try playlistItemRecords(playlistId: playlistId, db: db)
            let edited = PlaylistEditor.remove(original, at: index)
            try self.persistPlaylistItems(original: original, edited: edited, db: db)
        }
    }

    public func removeFromPlaylist(playlistId: Int64, atOffsets offsets: IndexSet) throws {
        try dbQueue.write { db in
            let original = try playlistItemRecords(playlistId: playlistId, db: db)
            let edited = PlaylistEditor.remove(original, atOffsets: offsets)
            try self.persistPlaylistItems(original: original, edited: edited, db: db)
        }
    }

    /// Creates a manual playlist from an ordered list of track ids.
    @discardableResult
    public func createManualPlaylist(title: String, trackIds: [Int64]) throws -> Playlist {
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

    private func playlistItemRecords(playlistId: Int64, db: Database) throws -> [PlaylistItem] {
        try PlaylistItem
            .filter(Column("playlistId") == playlistId)
            .order(Column("position"), Column("id"))
            .fetchAll(db)
    }

    private func persistPlaylistItems(
        original: [PlaylistItem],
        edited: [PlaylistItem],
        db: Database
    ) throws {
        let retainedIDs = Set(edited.compactMap(\.id))
        for item in original {
            guard let id = item.id, !retainedIDs.contains(id) else { continue }
            try PlaylistItem.deleteOne(db, key: id)
        }
        for item in edited {
            guard let id = item.id else { continue }
            try db.execute(
                sql: "UPDATE playlist_item SET position = ? WHERE id = ?",
                arguments: [item.position, id])
        }
    }

    // MARK: - Listening history (TF7)

    public func recordPlay(trackId: Int64) throws {
        try dbQueue.write { db in
            var event = PlayEvent(id: nil, trackId: trackId, playedAt: Date())
            try event.insert(db)
        }
    }

    /// Distinct tracks ordered by most-recently played, capped at `limit`.
    public func recentlyPlayedRows(limit: Int = 12) throws -> [TrackRow] {
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

    public func favoriteTrackIds() throws -> Set<Int64> {
        try dbQueue.read { db in
            let favs = try Favorite.fetchAll(db)
            return Set(favs.map { $0.trackId })
        }
    }

    public func setFavorite(trackId: Int64, _ isFavorite: Bool) throws {
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

    public func favoriteRows() throws -> [TrackRow] {
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
    public func recentlyAddedRows(limit: Int = 12) throws -> [TrackRow] {
        try dbQueue.read { db in
            let tracks = try Track.order(Column("id").desc).limit(limit).fetchAll(db)
            return try tracks.map { try self.hydrate($0, db: db) }
        }
    }

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
