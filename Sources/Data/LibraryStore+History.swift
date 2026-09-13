import Foundation
import GRDB

/// Listening history and favorites (TF7) — split out of
/// `LibraryStore.swift` (pure reorganization).
extension LibraryStore {

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

}
