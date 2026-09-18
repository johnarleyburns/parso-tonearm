import Foundation
import GRDB

// MARK: - DJ playlists
//
// Split out of `DJRecords.swift` — standalone record types, no cross-file
// access-level changes needed. This file used to also hold the
// `AutoPlaylistBrief`/`AutoPlaylistResult`/`AutoPlaylistItem`/
// `AutoPlaylistRejection` records for the DJ-mixer-era auto-playlist
// generator (prompt + arc → beam-searched sequence, §14.3) — that whole
// feature (`PlaylistGenerator`/`PlaylistSequencer`/`AutoPlaylistModel` and
// its Brief/Result UI) was orphaned dead code, never reachable from the live
// app (the DJ tab is `TransitionLabTabView`, not this), and was deleted.
// `DJPlaylist`/`DJPlaylistItem` below are unrelated, live records (used by
// `DJLibraryStore.saveCratePlaylist`/`GigCrateRepository`) and stayed.

/// A static playlist row in the DJ database (FR-PLIST-7 "Save as Playlist").
/// DJ-prefixed because `TonearmCore` already owns a `Playlist` record.
public struct DJPlaylist: Codable, Identifiable, FetchableRecord,
                          MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var title: String
    /// `manual|performance` (§14.3); a saved generated playlist is `manual`.
    public var kind: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, syncID: String, title: String,
                kind: String = "manual", createdAt: Date, updatedAt: Date) {
        self.id = id
        self.syncID = syncID
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "playlist"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One ordered row of a static DJ playlist (§14.3).
public struct DJPlaylistItem: Codable, Identifiable, FetchableRecord,
                              MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var playlistID: Int64
    public var trackID: Int64
    public var position: Int

    public init(id: Int64? = nil, playlistID: Int64, trackID: Int64, position: Int) {
        self.id = id
        self.playlistID = playlistID
        self.trackID = trackID
        self.position = position
    }

    public static let databaseTableName = "playlist_item"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
