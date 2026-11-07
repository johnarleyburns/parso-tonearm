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

    /// A custom decode, not the Codable-synthesized default: GRDB's default `FetchableRecord`
    /// conformance throws "column not found" for a non-optional property (even one with a Swift
    /// default value) when the column is genuinely absent from the row — which broke every test
    /// migrating to a pre-v46 schema snapshot and then fetching `Track` rows the moment `indexed`
    /// was added. `Row`'s own subscript, used directly here instead, treats a missing column the
    /// same as NULL (returns `nil`), so `indexed` safely falls back to `false` against any older
    /// schema instead of throwing.
    public init(row: Row) {
        self.init(
            id: row["id"], albumId: row["albumId"], sourceId: row["sourceId"], title: row["title"],
            trackNo: row["trackNo"], discNo: row["discNo"], durationSec: row["durationSec"],
            codec: row["codec"], sampleRate: row["sampleRate"],
            bitDepthOrBitrate: row["bitDepthOrBitrate"], sortKey: row["sortKey"],
            genre: row["genre"], composer: row["composer"], artistId: row["artistId"],
            rgTrackGain: row["rgTrackGain"], rgAlbumGain: row["rgAlbumGain"],
            rgTrackPeak: row["rgTrackPeak"], rgAlbumPeak: row["rgAlbumPeak"], syncID: row["syncID"],
            indexed: (row["indexed"] as Bool?) ?? false)
    }
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

