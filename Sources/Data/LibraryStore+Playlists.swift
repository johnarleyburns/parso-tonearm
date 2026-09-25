import Foundation
import GRDB

/// Playlist CRUD, reordering, and de-dup/merge maintenance — split out of
/// `LibraryStore.swift` (pure reorganization). The shared
/// `playlistItemRecords`/`persistPlaylistItems` helpers stay in the primary
/// file since the reorder/remove/dedup methods here all use them.
extension LibraryStore {

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
            if existing?.kind == .folder, let sourceId = existing?.sourceId {
                try db.execute(
                    sql: "UPDATE source SET title = ? WHERE id = ?",
                    arguments: [title, sourceId])
            }
        }
    }

    public func setPlaylistInCrate(id playlistId: Int64, isInCrate: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE playlist SET isInCrate = ? WHERE id = ?",
                arguments: [isInCrate, playlistId])
        }
    }

    public func deletePlaylist(id: Int64) throws {
        _ = try dbQueue.write { db in try Playlist.deleteOne(db, key: id) }
    }

    public func addToPlaylist(playlistId: Int64, trackId: Int64, sectionTitle: String? = nil) throws {
        try dbQueue.write { db in
            let exists = try PlaylistItem
                .filter(Column("playlistId") == playlistId && Column("trackId") == trackId)
                .fetchCount(db) > 0
            guard !exists else { return }
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

    public func playlistHasAnalyzedBPM(id playlistId: Int64) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM playlist_item i
                        JOIN discovery_track_analysis a ON a.trackId = i.trackId
                        WHERE i.playlistId = ? AND a.bpm IS NOT NULL)
                    """,
                arguments: [playlistId]) ?? false
        }
    }

    public func playlist(id: Int64) throws -> Playlist? {
        try dbQueue.read { db in try Playlist.fetchOne(db, key: id) }
    }

    /// Tracks of an album in disc/track order, hydrated. The watch collection-detail request
    /// (§6.2) resolves an album ref through here.
    public func albumTrackRows(albumId: Int64) throws -> [TrackRow] {
        try dbQueue.read { db in
            let tracks = try Track.fetchAll(db, sql: """
                SELECT track.* FROM track
                WHERE track.albumId = ?
                ORDER BY track.discNo, track.trackNo, track.sortKey
                """, arguments: [albumId])
            return try tracks.map { try self.hydrate($0, db: db) }
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

    /// Persists a complete ascending-BPM reorder in one transaction. The
    /// analysis join is intentionally local to this operation so unknown BPM
    /// values remain unknown and are sorted last rather than fabricated.
    public func sortPlaylistByBPM(id playlistId: Int64) throws {
        try dbQueue.write { db in
            let original = try playlistItemRecords(playlistId: playlistId, db: db)
            guard !original.isEmpty else { return }
            let trackIDs = original.map(\.trackId)
            let placeholders = trackIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT trackId, bpm FROM discovery_track_analysis
                    WHERE trackId IN (\(placeholders)) AND bpm IS NOT NULL
                    """,
                arguments: StatementArguments(trackIDs))
            var bpmByTrackID: [Int64: Double] = [:]
            for row in rows {
                if let bpm: Double = row["bpm"] {
                    bpmByTrackID[row["trackId"]] = bpm
                }
            }
            let edited = PlaylistEditor.sortedByBPM(original, bpmByTrackID: bpmByTrackID)
            try persistPlaylistItems(original: original, edited: edited, db: db)
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
            let uniqueTrackIDs = trackIds.reduce(into: [Int64]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            for (i, tid) in uniqueTrackIDs.enumerated() {
                var item = PlaylistItem(id: nil, playlistId: pid, position: i,
                                        trackId: tid, sectionTitle: nil)
                try item.insert(db)
            }
            return pl
        }
    }

    public func removeDuplicatePlaylistItems() throws -> Int {
        try dbQueue.write { db in
            let playlistIDs = try Int64.fetchAll(db, sql: "SELECT id FROM playlist ORDER BY id")
            var removed = 0
            for playlistID in playlistIDs {
                let original = try self.playlistItemRecords(playlistId: playlistID, db: db)
                let edited = PlaylistDedup.deduplicated(original)
                removed += original.count - edited.count
                try self.persistPlaylistItems(original: original, edited: edited, db: db)
            }
            return removed
        }
    }

    public func mergeDuplicateFolderPlaylists() throws -> Int {
        try dbQueue.write { db in
            let playlists = try Playlist
                .filter(Column("kind") == PlaylistKind.folder.rawValue)
                .order(Column("id")).fetchAll(db)
            var groups: [String: [Playlist]] = [:]
            for playlist in playlists {
                var key: String?
                if let bookmark = playlist.folderBookmark,
                   let (url, _) = BookmarkVault.resolve(bookmark) {
                    key = FolderImportIdentity.key(for: url)
                } else if let sourceID = playlist.sourceId,
                          let source = try Source.fetchOne(db, key: sourceID) {
                    key = source.folderPath
                }
                guard let key else { continue }
                groups[key, default: []].append(playlist)
            }

            var merged = 0
            for (key, group) in groups where group.count > 1 {
                guard let keeper = group.min(by: { ($0.id ?? .max) < ($1.id ?? .max) }),
                      let keeperID = keeper.id else { continue }
                var keeperSourceID = keeper.sourceId
                if keeperSourceID == nil,
                   let adoptedSourceID = group.compactMap(\.sourceId).first {
                    keeperSourceID = adoptedSourceID
                    try db.execute(sql: "UPDATE playlist SET sourceId = ? WHERE id = ?",
                                   arguments: [adoptedSourceID, keeperID])
                }
                if let sourceID = keeperSourceID {
                    try db.execute(sql: "UPDATE source SET folderPath = ? WHERE id = ?",
                                   arguments: [key, sourceID])
                }
                var existing = Set(try Int64.fetchAll(db, sql:
                    "SELECT trackId FROM playlist_item WHERE playlistId = ?", arguments: [keeperID]))
                var next = (try Int.fetchOne(db, sql:
                    "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_item WHERE playlistId = ?",
                    arguments: [keeperID])) ?? 0
                for duplicate in group where duplicate.id != keeper.id {
                    guard let duplicateID = duplicate.id else { continue }
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT trackId, sectionTitle FROM playlist_item
                        WHERE playlistId = ? ORDER BY position, id
                        """, arguments: [duplicateID])
                    for row in rows {
                        let trackID: Int64 = row["trackId"]
                        guard existing.insert(trackID).inserted else { continue }
                        let section: String? = row["sectionTitle"]
                        try db.execute(sql: """
                            INSERT INTO playlist_item (playlistId, position, trackId, sectionTitle)
                            VALUES (?, ?, ?, ?)
                            """, arguments: [keeperID, next, trackID, section])
                        next += 1
                    }
                    try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [duplicateID])
                    if let duplicateSourceID = duplicate.sourceId,
                       duplicateSourceID != keeperSourceID {
                        if let keeperSourceID {
                            try db.execute(sql: "UPDATE album SET sourceId = ? WHERE sourceId = ?",
                                           arguments: [keeperSourceID, duplicateSourceID])
                            try db.execute(sql: "UPDATE track SET sourceId = ? WHERE sourceId = ?",
                                           arguments: [keeperSourceID, duplicateSourceID])
                        }
                        try db.execute(sql: "DELETE FROM source WHERE id = ?",
                                       arguments: [duplicateSourceID])
                    }
                    merged += 1
                }
            }
            return merged
        }
    }

    public func remoteURLs(forSource sourceID: Int64) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT asset.remoteURL FROM asset
                JOIN track ON track.id = asset.trackId
                WHERE track.sourceId = ? AND asset.remoteURL IS NOT NULL
                """, arguments: [sourceID]))
        }
    }

    public func localFilePaths(forSource sourceID: Int64) throws -> Set<String> {
        try dbQueue.read { db in
            let bookmarks = try Data.fetchAll(db, sql: """
                SELECT asset.bookmark FROM asset
                JOIN track ON track.id = asset.trackId
                WHERE track.sourceId = ? AND asset.bookmark IS NOT NULL
                """, arguments: [sourceID])
            return Set(bookmarks.compactMap { bookmark in
                BookmarkVault.resolve(bookmark).map { FolderImportIdentity.key(for: $0.url) }
            })
        }
    }

}
