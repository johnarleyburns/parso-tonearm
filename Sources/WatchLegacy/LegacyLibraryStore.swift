import Foundation
import GRDB
import TonearmWatchProtocol

public enum LegacyWatchPlaylistKind: String, Codable, DatabaseValueConvertible, Sendable { case manual, folder }

public struct LegacyWatchPlaylist: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "playlist"
    public var id: Int64?
    public var title: String
    public var kind: LegacyWatchPlaylistKind
    public var syncID: String?
    public init(id: Int64? = nil, title: String, kind: LegacyWatchPlaylistKind = .manual, syncID: String? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.syncID = syncID
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct LegacyWatchAlbum: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "album"
    public var id: Int64?
    public var syncID: String
    public var title: String
    public var artist: String?
    public var albumArtist: String?
    public var artworkId: String?
    public init(id: Int64? = nil, syncID: String, title: String, artist: String? = nil,
                albumArtist: String? = nil, artworkId: String? = nil) {
        self.id = id; self.syncID = syncID; self.title = title; self.artist = artist
        self.albumArtist = albumArtist; self.artworkId = artworkId
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct LegacyWatchArtist: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "artist"
    public var id: Int64?
    public var syncID: String
    public var name: String
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct LegacyWatchTrack: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "track"
    public var id: Int64?
    public var syncID: String
    public var albumId: Int64?
    public var artistId: Int64?
    public var title: String
    public var durationSec: Double?
    public var sortKey: String?
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct LegacyWatchAsset: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "asset"
    public var id: Int64?
    public var trackId: Int64
    public var relPath: String?
    public var remoteURL: String?
    public var altRemoteURL: String?
    public var sizeBytes: Int64?
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct LegacyWatchPlaylistItem: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "playlistItem"
    public var id: Int64?
    public var playlistId: Int64
    public var trackId: Int64
    public var ordinal: Int
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct LegacyWatchManifestRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public var trackKey: String
    public var bytes: Int64
    public var pinned: Bool
    public var reportedAt: Date
    public static let databaseTableName = "watchManifest"
}

public struct LegacyWatchTrackRow: Identifiable, Hashable, Sendable {
    public var track: LegacyWatchTrack
    public var album: LegacyWatchAlbum?
    public var artist: LegacyWatchArtist?
    public var asset: LegacyWatchAsset?
    public var id: Int64 { track.id ?? -1 }
}

public struct LegacyWatchPlaylistTrackRow: Identifiable, Sendable {
    public var id: Int64
    public var row: LegacyWatchTrackRow
}

public final class LegacyWatchLibraryStore: @unchecked Sendable {
    public static let shared: LegacyWatchLibraryStore = {
        do { return try LegacyWatchLibraryStore() }
        catch { fatalError("Unable to open temporary watch library: \(error)") }
    }()

    private let db: any DatabaseWriter

    public init(inMemory: Bool = false) throws {
        if inMemory { db = try DatabaseQueue() }
        else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            db = try DatabasePool(path: root.appendingPathComponent("PlatterheadWatchLegacy.sqlite").path)
        }
        try migrate()
        if !inMemory { try adoptExistingWatchDatabaseIfNeeded() }
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("legacy_v1") { db in
            try db.create(table: "playlist") { t in t.autoIncrementedPrimaryKey("id"); t.column("title", .text).notNull(); t.column("kind", .text).notNull(); t.column("syncID", .text).unique() }
            try db.create(table: "album") { t in t.autoIncrementedPrimaryKey("id"); t.column("syncID", .text).notNull().unique(); t.column("title", .text).notNull(); t.column("artist", .text); t.column("albumArtist", .text); t.column("artworkId", .text) }
            try db.create(table: "artist") { t in t.autoIncrementedPrimaryKey("id"); t.column("syncID", .text).notNull().unique(); t.column("name", .text).notNull() }
            try db.create(table: "track") { t in t.autoIncrementedPrimaryKey("id"); t.column("syncID", .text).notNull().unique(); t.column("albumId", .integer); t.column("artistId", .integer); t.column("title", .text).notNull(); t.column("durationSec", .double); t.column("sortKey", .text) }
            try db.create(table: "asset") { t in t.autoIncrementedPrimaryKey("id"); t.column("trackId", .integer).notNull().unique(); t.column("relPath", .text); t.column("remoteURL", .text); t.column("altRemoteURL", .text); t.column("sizeBytes", .integer) }
            try db.create(table: "playlistItem") { t in t.autoIncrementedPrimaryKey("id"); t.column("playlistId", .integer).notNull(); t.column("trackId", .integer).notNull(); t.column("ordinal", .integer).notNull() }
            try db.create(table: "watchManifest") { t in t.column("trackKey", .text).primaryKey(); t.column("bytes", .integer).notNull(); t.column("pinned", .boolean).notNull(); t.column("reportedAt", .datetime).notNull() }
        }
        try migrator.migrate(db)
    }

    /// Phase 1 keeps installed users whole while changing the package boundary.
    /// The old broad-core store remains read-only evidence; its rows are copied
    /// once into the isolated compatibility store and the original is retained
    /// for the Phase 6 SwiftData cutover/recovery pass.
    private func adoptExistingWatchDatabaseIfNeeded() throws {
        let hasTracks = try db.read { try LegacyWatchTrack.fetchCount($0) > 0 }
        guard !hasTracks else { return }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldURL = root.appendingPathComponent("Tonearm/library.sqlite")
        guard FileManager.default.fileExists(atPath: oldURL.path) else { return }
        let old = try DatabaseQueue(path: oldURL.path)

        let snapshot = try old.read { oldDB -> LegacySnapshot in
            let artists = try Row.fetchAll(oldDB, sql: "SELECT id, syncID, name FROM artist").map { row in
                let id: Int64 = row["id"]
                return LegacyWatchArtist(id: id, syncID: row["syncID"] ?? "ar\(id)", name: row["name"])
            }
            let albums = try Row.fetchAll(oldDB, sql: "SELECT id, syncID, title, artist, albumArtist, artworkId FROM album").map { row in
                let id: Int64 = row["id"]
                return LegacyWatchAlbum(id: id, syncID: row["syncID"] ?? "a\(id)", title: row["title"], artist: row["artist"], albumArtist: row["albumArtist"], artworkId: row["artworkId"])
            }
            let tracks = try Row.fetchAll(oldDB, sql: "SELECT id, syncID, albumId, artistId, title, durationSec, sortKey FROM track").map { row in
                let id: Int64 = row["id"]
                return LegacyWatchTrack(id: id, syncID: row["syncID"] ?? "t\(id)", albumId: row["albumId"], artistId: row["artistId"], title: row["title"], durationSec: row["durationSec"], sortKey: row["sortKey"])
            }
            let assets = try Row.fetchAll(oldDB, sql: "SELECT id, trackId, relPath, remoteURL, altRemoteURL, sizeBytes FROM asset ORDER BY id").map {
                LegacyWatchAsset(id: $0["id"], trackId: $0["trackId"], relPath: $0["relPath"], remoteURL: $0["remoteURL"], altRemoteURL: $0["altRemoteURL"], sizeBytes: $0["sizeBytes"])
            }
            let playlists = try Row.fetchAll(oldDB, sql: "SELECT id, title, kind, syncID FROM playlist").map { row in
                let id: Int64 = row["id"]
                return LegacyWatchPlaylist(id: id, title: row["title"], kind: LegacyWatchPlaylistKind(rawValue: row["kind"]) ?? .manual, syncID: row["syncID"] ?? "p\(id)")
            }
            let items = try Row.fetchAll(oldDB, sql: "SELECT id, playlistId, trackId, position FROM playlist_item").map {
                LegacyWatchPlaylistItem(id: $0["id"], playlistId: $0["playlistId"], trackId: $0["trackId"], ordinal: $0["position"])
            }
            let manifests = (try? Row.fetchAll(oldDB, sql: "SELECT trackKey, bytes, pinned, reportedAt FROM watchManifest").map {
                LegacyWatchManifestRecord(trackKey: $0["trackKey"], bytes: $0["bytes"], pinned: $0["pinned"], reportedAt: $0["reportedAt"])
            }) ?? []
            return LegacySnapshot(artists: artists, albums: albums, tracks: tracks, assets: assets,
                                  playlists: playlists, items: items, manifests: manifests)
        }
        try db.write { newDB in try snapshot.insert(into: newDB) }
    }

    public func allPlaylists() async throws -> [LegacyWatchPlaylist] { try await db.read { try LegacyWatchPlaylist.order(Column("title")).fetchAll($0) } }
    public func allAlbums() async throws -> [LegacyWatchAlbum] { try await db.read { try LegacyWatchAlbum.order(Column("title")).fetchAll($0) } }
    public func allTracks() async throws -> [LegacyWatchTrack] { try await db.read { try LegacyWatchTrack.fetchAll($0) } }
    public func allTrackRows() async throws -> [LegacyWatchTrackRow] { try await db.read { db in try Self.rows(in: db) } }
    public func trackBySyncID(_ key: String) async throws -> LegacyWatchTrack? { try await db.read { try LegacyWatchTrack.filter(Column("syncID") == key).fetchOne($0) } }
    public func playlistTrackRows(playlistId: Int64) async throws -> [LegacyWatchPlaylistTrackRow] {
        try await db.read { db in
            let items = try LegacyWatchPlaylistItem.filter(Column("playlistId") == playlistId).order(Column("ordinal")).fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: try Self.rows(in: db).map { ($0.id, $0) })
            return items.compactMap { item in byID[item.trackId].map { LegacyWatchPlaylistTrackRow(id: item.id ?? Int64(item.ordinal), row: $0) } }
        }
    }
    public func manifests() async throws -> [LegacyWatchManifestRecord] { try await db.read { try LegacyWatchManifestRecord.fetchAll($0) } }
    public func title(forTrackKey key: String) async -> String? { try? await db.read { try LegacyWatchTrack.filter(Column("syncID") == key).fetchOne($0)?.title } }
    public func removeManifest(keys: [String]) async throws { try await db.write { db in for key in keys { _ = try LegacyWatchManifestRecord.deleteOne(db, key: key) } } }
    public func removeAllManifests() async throws { _ = try await db.write { try LegacyWatchManifestRecord.deleteAll($0) } }
    public func deleteTrack(key: String) async throws { try await db.write { db in if let track = try LegacyWatchTrack.filter(Column("syncID") == key).fetchOne(db), let id = track.id { _ = try LegacyWatchTrack.deleteOne(db, key: id); try LegacyWatchAsset.filter(Column("trackId") == id).deleteAll(db); try LegacyWatchPlaylistItem.filter(Column("trackId") == id).deleteAll(db) } } }

    public func installAudio(key: String, relativePath: String, metadata: WatchAudioMetadata) async throws -> Bool {
        try await db.write { db in
            guard let track = try LegacyWatchTrack.filter(Column("syncID") == key).fetchOne(db), let id = track.id else { return false }
            try LegacyWatchAsset.filter(Column("trackId") == id).deleteAll(db)
            var asset = LegacyWatchAsset(id: nil, trackId: id, relPath: relativePath, remoteURL: nil, altRemoteURL: nil, sizeBytes: metadata.bytes)
            try asset.insert(db)
            let manifest = LegacyWatchManifestRecord(trackKey: key, bytes: metadata.bytes, pinned: metadata.pinned, reportedAt: Date())
            try manifest.save(db)
            return true
        }
    }

    public func importCatalog(_ snapshot: WatchCatalogSnapshot) async throws {
        try await db.write { db in
            var artistIDs: [String: Int64] = [:]
            for dto in snapshot.artists { var value = LegacyWatchArtist(id: nil, syncID: dto.key, name: dto.name); try value.upsert(db); artistIDs[dto.key] = try LegacyWatchArtist.filter(Column("syncID") == dto.key).fetchOne(db)?.id }
            var albumIDs: [String: Int64] = [:]
            for dto in snapshot.albums { var value = LegacyWatchAlbum(id: nil, syncID: dto.key, title: dto.title, artist: dto.artist, albumArtist: dto.artist, artworkId: dto.artworkId); try value.upsert(db); albumIDs[dto.key] = try LegacyWatchAlbum.filter(Column("syncID") == dto.key).fetchOne(db)?.id }
            var trackIDs: [String: Int64] = [:]
            for dto in snapshot.tracks {
                let existing = try LegacyWatchTrack.filter(Column("syncID") == dto.key).fetchOne(db)
                var value = LegacyWatchTrack(id: existing?.id, syncID: dto.key, albumId: dto.albumKey.flatMap { albumIDs[$0] }, artistId: dto.artistKey.flatMap { artistIDs[$0] }, title: dto.title, durationSec: dto.durationSec, sortKey: dto.sortKey)
                try value.save(db); guard let id = value.id else { continue }; trackIDs[dto.key] = id
                if dto.remoteURL != nil || dto.altRemoteURL != nil { var asset = LegacyWatchAsset(id: try LegacyWatchAsset.filter(Column("trackId") == id).fetchOne(db)?.id, trackId: id, relPath: try LegacyWatchAsset.filter(Column("trackId") == id).fetchOne(db)?.relPath, remoteURL: dto.remoteURL, altRemoteURL: dto.altRemoteURL, sizeBytes: dto.sizeBytes); try asset.save(db) }
            }
            for dto in snapshot.playlists {
                var playlist = LegacyWatchPlaylist(id: try LegacyWatchPlaylist.filter(Column("syncID") == dto.key).fetchOne(db)?.id, title: dto.title, kind: .manual, syncID: dto.key); try playlist.save(db)
                guard let id = playlist.id else { continue }; try LegacyWatchPlaylistItem.filter(Column("playlistId") == id).deleteAll(db)
                for (ordinal, key) in dto.trackKeys.enumerated() { if let trackID = trackIDs[key] { var item = LegacyWatchPlaylistItem(id: nil, playlistId: id, trackId: trackID, ordinal: ordinal); try item.insert(db) } }
            }
        }
    }

    public func seedFixture(title: String, audioRelativePath: String) async throws {
        try await db.write { db in
            if try LegacyWatchPlaylist.filter(Column("title") == "Built-in Playlist").fetchCount(db) > 0 { return }
            var album = LegacyWatchAlbum(id: nil, syncID: "fixture-album", title: "Built-in Sounds", artist: "Built-in", albumArtist: "Built-in", artworkId: nil); try album.insert(db)
            var track = LegacyWatchTrack(id: nil, syncID: "fixture-track", albumId: album.id, artistId: nil, title: title, durationSec: 8, sortKey: title); try track.insert(db)
            guard let trackID = track.id else { return }; var asset = LegacyWatchAsset(id: nil, trackId: trackID, relPath: audioRelativePath, remoteURL: nil, altRemoteURL: nil, sizeBytes: 0); try asset.insert(db)
            var playlist = LegacyWatchPlaylist(id: nil, title: "Built-in Playlist", kind: .manual, syncID: "fixture-playlist"); try playlist.insert(db)
            if let playlistID = playlist.id { var item = LegacyWatchPlaylistItem(id: nil, playlistId: playlistID, trackId: trackID, ordinal: 0); try item.insert(db) }
            let manifest = LegacyWatchManifestRecord(trackKey: "fixture-track", bytes: 0, pinned: true, reportedAt: Date()); try manifest.save(db)
        }
    }

    private static func rows(in db: Database) throws -> [LegacyWatchTrackRow] {
        let tracks = try LegacyWatchTrack.fetchAll(db), albums = try LegacyWatchAlbum.fetchAll(db), artists = try LegacyWatchArtist.fetchAll(db), assets = try LegacyWatchAsset.fetchAll(db)
        let albumMap = Dictionary(uniqueKeysWithValues: albums.compactMap { album in album.id.map { ($0, album) } })
        let artistMap = Dictionary(uniqueKeysWithValues: artists.compactMap { artist in artist.id.map { ($0, artist) } })
        let assetMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.trackId, $0) })
        return tracks.map { LegacyWatchTrackRow(track: $0, album: $0.albumId.flatMap { albumMap[$0] }, artist: $0.artistId.flatMap { artistMap[$0] }, asset: $0.id.flatMap { assetMap[$0] }) }
    }
}

private struct LegacySnapshot {
    var artists: [LegacyWatchArtist]
    var albums: [LegacyWatchAlbum]
    var tracks: [LegacyWatchTrack]
    var assets: [LegacyWatchAsset]
    var playlists: [LegacyWatchPlaylist]
    var items: [LegacyWatchPlaylistItem]
    var manifests: [LegacyWatchManifestRecord]

    func insert(into db: Database) throws {
        for var value in artists { try value.insert(db, onConflict: .ignore) }
        for var value in albums { try value.insert(db, onConflict: .ignore) }
        for var value in tracks { try value.insert(db, onConflict: .ignore) }
        var seenTrackIDs = Set<Int64>()
        for var value in assets where seenTrackIDs.insert(value.trackId).inserted { try value.insert(db, onConflict: .ignore) }
        for var value in playlists { try value.insert(db, onConflict: .ignore) }
        for var value in items { try value.insert(db, onConflict: .ignore) }
        for value in manifests { try value.insert(db, onConflict: .replace) }
    }
}

public enum WatchStorage { public static let watchAudioDirName = "WatchAudio"; public static let cacheDirName = "WatchCache"; public static let orphansDirName = "WatchOrphans" }
