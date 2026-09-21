import Foundation
import GRDB

public struct TrackRow: Identifiable, Equatable, Sendable {
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

public struct PlaylistTrackRow: Identifiable, Equatable, Sendable {
    public var item: PlaylistItem
    public var row: TrackRow
    public var id: Int64 { item.id ?? -1 }

    public init(item: PlaylistItem, row: TrackRow) {
        self.item = item
        self.row = row
    }
}

/// The library database. The bulk of its query surface lives in
/// `LibraryStore+*.swift` files split by concern (a pure reorganization —
/// see docs/plans/refactor-400-lines/STATUS.md): `+Sources` (sources and
/// per-item custom artwork), `+Catalog` (albums/tracks/assets + search),
/// `+Playlists`, `+History` (listening history/favorites), and `+Sync`
/// (cache entries, the sync snapshot reads, single-row deletes/updates,
/// syncID lookups). What stays here — besides `init` — is the row-hydration
/// and search-index machinery those extensions share.
public actor LibraryStore {
    public static let shared = try! LibraryStore()

    public let dbQueue: DatabaseQueue

    public init(inMemory: Bool = false) throws {
        // Real incident: `Tests/PlaybackPositionLossTests.swift` inserted
        // "PosTest*" fixture rows straight into `LibraryStore.shared`
        // because the code path under test (`AudioPlayer.shared
        // .restorePersistedQueue()`) hydrates via `.shared` internally with
        // no injection seam — swapping just the insert call to an isolated
        // store would have broken the test's own premise. On a real Mac,
        // `swift test` runs as a plain, unsandboxed process, so `.shared`'s
        // "real" path IS the same on-disk file the actual (also
        // unsandboxed Catalyst) app reads — every `swift test` run this
        // session had been silently polluting the owner's real Mac
        // library. `XCTestConfigurationFilePath` is the standard, reliable
        // signal XCTest sets for the whole test process — redirecting
        // `.shared` itself to a per-run temporary directory whenever it's
        // present makes this impossible to repeat, for any test, without
        // requiring every future test author to remember `inMemory: true`.
        // `XCTestConfigurationFilePath` alone is not reliable here — verified
        // directly that a plain `swift test` run does NOT set it, only
        // `ProcessInfo.processInfo.processName == "xctest"` (the real Apple
        // test-runner binary hosting the test bundle) and the `SWIFT_TESTING_ENABLED`
        // key (present regardless of its value once SwiftPM's test plumbing is
        // active). Checking all three covers both `swift test` and an Xcode-
        // hosted `xcodebuild test` run.
        let isRunningUnderXCTest = ProcessInfo.processInfo.processName == "xctest"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] != nil
        if inMemory {
            dbQueue = try DatabaseQueue()
        } else {
            let fm = FileManager.default
            let dir: URL
            if isRunningUnderXCTest {
                dir = fm.temporaryDirectory
                    .appendingPathComponent("TonearmXCTestLibraryStore-\(UUID().uuidString)", isDirectory: true)
            } else {
                dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
                    .appendingPathComponent("Tonearm", isDirectory: true)
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var config = Configuration()
            config.foreignKeysEnabled = true
            dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("library.sqlite").path,
                                        configuration: config)
        }
        try Schema.migrator().migrate(dbQueue)
    }

    // MARK: - Shared row-hydration / search-index helpers
    //
    // Used from LibraryStore+Catalog.swift, +Search (also in +Catalog),
    // +Playlists.swift and +History.swift — kept here (rather than `private`
    // in whichever file happened to declare them first) because `private` in
    // Swift is file-scoped, not type-scoped, and these are genuinely shared
    // across extension files.

    func hydrate(_ track: Track, db: Database) throws -> TrackRow {
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

    func artistID(for rawName: String, db: Database) throws -> Int64? {
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

    func refreshSearchIndex(trackID: Int64?, db: Database) throws {
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

    func searchFilename(relPath: String?, remoteURL: String?, altRemoteURL: String?) -> String {
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

    // MARK: - Shared playlist-item persistence helpers
    //
    // Used by every reorder/remove/dedup method in LibraryStore+Playlists.swift.

    func playlistItemRecords(playlistId: Int64, db: Database) throws -> [PlaylistItem] {
        try PlaylistItem
            .filter(Column("playlistId") == playlistId)
            .order(Column("position"), Column("id"))
            .fetchAll(db)
    }

    func persistPlaylistItems(
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
}
