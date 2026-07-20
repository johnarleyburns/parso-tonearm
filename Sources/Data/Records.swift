import Foundation
import GRDB

extension Source: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "source"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Album: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "album"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Artist: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "artist"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Track: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "track"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Asset: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "asset"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension CacheEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "cache_entry"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Playlist: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension PlaylistItem: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist_item"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension PlayEvent: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "play_history"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Favorite: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "favorite"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension WatchTransferRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "watchTransfer"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension WatchManifestRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "watchManifest"
}
