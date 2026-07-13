import Foundation
import GRDB

extension Source: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "source"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Album: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "album"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Track: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "track"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Asset: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "asset"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension CacheEntry: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "cache_entry"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Playlist: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "playlist"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension PlaylistItem: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "playlist_item"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension PlayEvent: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "play_history"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Favorite: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "favorite"
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

