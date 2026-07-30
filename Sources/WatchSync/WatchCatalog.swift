import Foundation
import GRDB

public enum WatchCatalog {

    public static func key(for trackId: Int64) -> String { "t\(trackId)" }
    public static func albumKey(for albumId: Int64) -> String { "a\(albumId)" }
    public static func playlistKey(for playlistId: Int64) -> String { "p\(playlistId)" }
    public static func artistKey(for artistId: Int64) -> String { "ar\(artistId)" }
    public static func sourceKey() -> String { "iPhone" }

    // MARK: - Export (phone side)

    public static func export(from store: LibraryStore) async throws -> WatchCatalogSnapshot {
        let allTracks = try await store.allTracks()
        let allAssets = try await store.allAssets()
        let allAlbums = try await store.allAlbums()
        let allPlaylists = try await store.allPlaylists()
        let allArtists = try await store.allArtists()

        let artistMap = Dictionary(uniqueKeysWithValues: allArtists.compactMap { a -> (Int64, Artist)? in
            guard let id = a.id else { return nil }
            return (id, a)
        })
        var assetMap: [Int64: Asset] = [:]
        for asset in allAssets where asset.trackId > 0 && assetMap[asset.trackId] == nil {
            assetMap[asset.trackId] = asset
        }
        let albumIDs = Set(allAlbums.compactMap(\.id))

        let albumDTOs: [WatchAlbumDTO] = allAlbums.compactMap { album in
            guard let id = album.id else { return nil }
            let aKey = album.artistId.map(artistKey(for:))
            return WatchAlbumDTO(
                key: albumKey(for: id),
                title: album.title,
                artist: album.artist ?? album.albumArtist,
                artistKey: aKey,
                artworkId: album.artworkId,
                year: album.year)
        }

        let artistDTOs: [WatchArtistDTO] = allArtists.map { artist in
            WatchArtistDTO(key: artistKey(for: artist.id ?? -1), name: artist.name)
        }

        let trackDTOs: [WatchTrackDTO] = allTracks.compactMap { track in
            guard let id = track.id else { return nil }
            let aKey: String?
            if let albumId = track.albumId, albumIDs.contains(albumId) {
                aKey = albumKey(for: albumId)
            } else {
                aKey = nil
            }
            var artist: String?
            var trackArtistKey: String?
            if let artistId = track.artistId, let a = artistMap[artistId] {
                artist = a.name
                trackArtistKey = artistKey(for: artistId)
            }
            let asset = assetMap[id]
            return WatchTrackDTO(
                key: key(for: id),
                title: track.title,
                artist: artist,
                artistKey: trackArtistKey,
                albumKey: aKey,
                durationSec: track.durationSec,
                codec: track.codec,
                sizeBytes: asset?.sizeBytes,
                trackNo: track.trackNo,
                discNo: track.discNo,
                sortKey: track.sortKey,
                remoteURL: streamableURLString(asset?.remoteURL),
                altRemoteURL: streamableURLString(asset?.altRemoteURL))
        }

        var playlistDTOs: [WatchPlaylistDTO] = []
        for playlist in allPlaylists {
            guard let pid = playlist.id else { continue }
            let items: [String] = uniquePreservingOrder(((try? await store.playlistTrackRows(playlistId: pid))?.compactMap { ptr in
                guard let tid = ptr.row.track.id else { return nil }
                return key(for: tid)
            }) ?? [])
            playlistDTOs.append(WatchPlaylistDTO(key: playlistKey(for: pid), title: playlist.title, trackKeys: items))
        }

        return WatchCatalogSnapshot(
            version: Int(Date().timeIntervalSince1970),
            playlists: playlistDTOs,
            albums: albumDTOs,
            artists: artistDTOs,
            tracks: trackDTOs)
    }

    // MARK: - Import (watch side)

    public struct ImportResult: Equatable {
        public var upsertedTracks: Int = 0
        public var upsertedAlbums: Int = 0
        public var upsertedArtists: Int = 0
        public var upsertedPlaylists: Int = 0
        public var deletedTracks: Int = 0
    }

    public static func `import`(_ catalog: WatchCatalogSnapshot,
                                into store: LibraryStore) async throws -> ImportResult {
        var result = ImportResult()

        let source = try await ensureSource(in: store)
        guard let sourceId = source.id else { return result }

        let artistKeyMap = try await upsertArtists(catalog.artists, into: store, result: &result)
        let albumKeyMap = try await upsertAlbums(catalog.albums, sourceId: sourceId,
                                                  artistKeyMap: artistKeyMap,
                                                  into: store, result: &result)
        let trackKeyMap = try await upsertTracks(catalog.tracks, sourceId: sourceId,
                                                  albumKeyMap: albumKeyMap,
                                                  artistKeyMap: artistKeyMap,
                                                  into: store, result: &result)
        try await upsertPlaylists(catalog.playlists, trackKeyMap: trackKeyMap,
                                   into: store, result: &result)
        result.deletedTracks = try await deleteStaleTracks(
            trackKeys: Set(catalog.tracks.map(\.key)),
            sourceId: sourceId, in: store)

        return result
    }

    public static func isStale(_ catalog: WatchCatalogSnapshot, lastVersion: Int) -> Bool {
        catalog.version <= lastVersion
    }

    // MARK: - Private

    private static func ensureSource(in store: LibraryStore) async throws -> Source {
        let title = sourceKey()
        if let existing = try await store.firstSource(title: title, kind: .local) {
            return existing
        }
        let src = Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
            title: title, addedAt: Date(), lastResolvedAt: Date(),
            followUpdates: false, licenseText: nil, memberCapHit: false,
            localIsFolder: false)
        return try await store.insertSource(src)
    }

    private static func upsertArtists(_ dtos: [WatchArtistDTO], into store: LibraryStore,
                                       result: inout ImportResult) async throws -> [String: Int64] {
        var map: [String: Int64] = [:]
        for dto in dtos {
            let artist = try await store.findOrCreateArtist(name: dto.name, sortName: ArtistNamePolicy.sortName(for: dto.name))
            if let id = artist.id { map[dto.key] = id }
        }
        result.upsertedArtists = dtos.count
        return map
    }

    private static func upsertAlbums(_ dtos: [WatchAlbumDTO], sourceId: Int64,
                                      artistKeyMap: [String: Int64],
                                      into store: LibraryStore,
                                      result: inout ImportResult) async throws -> [String: Int64] {
        var map: [String: Int64] = [:]
        for dto in dtos {
            let artistId = try await artistId(for: dto.artist,
                                              artistKey: dto.artistKey,
                                              artistKeyMap: artistKeyMap,
                                              store: store)
            if let existing = try await store.albumByTitle(dto.title, sourceId: sourceId) {
                var album = existing
                var changed = false
                if album.artist != dto.artist { album.artist = dto.artist; changed = true }
                if album.year != dto.year { album.year = dto.year; changed = true }
                if album.albumArtist != dto.artist { album.albumArtist = dto.artist; changed = true }
                if album.artworkId != dto.artworkId { album.artworkId = dto.artworkId; changed = true }
                if album.artistId != artistId { album.artistId = artistId; changed = true }
                if changed { _ = try await store.updateAlbum(album) }
                if let id = album.id { map[dto.key] = id }
            } else {
                var album = Album(id: nil, sourceId: sourceId, title: dto.title,
                                   artist: dto.artist, artistId: artistId,
                                   albumArtist: dto.artist, year: dto.year,
                                   artworkId: dto.artworkId)
                let inserted = try await store.insertAlbum(album)
                album = inserted
                if let id = album.id { map[dto.key] = id }
            }
        }
        result.upsertedAlbums = dtos.count
        return map
    }

    private static func upsertTracks(_ dtos: [WatchTrackDTO], sourceId: Int64,
                                      albumKeyMap: [String: Int64],
                                      artistKeyMap: [String: Int64],
                                      into store: LibraryStore,
                                      result: inout ImportResult) async throws -> [String: Int64] {
        var map: [String: Int64] = [:]
        for dto in dtos {
            let albumId = dto.albumKey.flatMap { albumKeyMap[$0] }
            let artistId = try await artistId(for: dto.artist,
                                              artistKey: dto.artistKey,
                                              artistKeyMap: artistKeyMap,
                                              store: store)

            if let existing = try await store.trackBySyncID(dto.key) {
                var track = existing
                var changed = false
                if track.title != dto.title { track.title = dto.title; changed = true }
                if track.albumId != albumId { track.albumId = albumId; changed = true }
                if track.durationSec != dto.durationSec { track.durationSec = dto.durationSec; changed = true }
                if track.codec != dto.codec { track.codec = dto.codec; changed = true }
                if track.trackNo != dto.trackNo { track.trackNo = dto.trackNo; changed = true }
                if track.discNo != dto.discNo { track.discNo = dto.discNo; changed = true }
                if track.sortKey != dto.sortKey { track.sortKey = dto.sortKey; changed = true }
                if track.artistId != artistId { track.artistId = artistId; changed = true }
                if changed {
                    _ = try await store.updateTrack(track)
                    result.upsertedTracks += 1
                }
                if let id = track.id {
                    map[dto.key] = id
                    try await upsertRemoteAsset(forTrackId: id, dto: dto, store: store)
                }
            } else {
                var track = Track(id: nil, albumId: albumId, sourceId: sourceId,
                                   title: dto.title, trackNo: dto.trackNo,
                                   discNo: dto.discNo, durationSec: dto.durationSec,
                                   codec: dto.codec, sampleRate: nil,
                                   bitDepthOrBitrate: nil, sortKey: dto.sortKey,
                                   artistId: artistId, syncID: dto.key)
                let inserted = try await store.insertTrack(track)
                track = inserted
                result.upsertedTracks += 1
                if let id = track.id {
                    map[dto.key] = id
                    try await upsertRemoteAsset(forTrackId: id, dto: dto, store: store)
                }
            }
        }
        return map
    }

    private static func upsertPlaylists(_ dtos: [WatchPlaylistDTO],
                                         trackKeyMap: [String: Int64],
                                         into store: LibraryStore,
                                         result: inout ImportResult) async throws {
        let importedKeys = Set(dtos.map(\.key))
        for dto in dtos {
            let trackIds = uniquePreservingOrder(dto.trackKeys).compactMap { trackKeyMap[$0] }
            try await replaceManualPlaylist(dto: dto, trackIds: trackIds, in: store)
            result.upsertedPlaylists += 1
        }
        try await deleteStalePlaylists(importedKeys: importedKeys, in: store)
    }

    private static func deleteStaleTracks(trackKeys: Set<String>,
                                           sourceId: Int64,
                                           in store: LibraryStore) async throws -> Int {
        let existing = try await store.allTracks()
        let stale = existing.filter { $0.sourceId == sourceId }
        var deleted = 0
        for track in stale {
            guard let sid = track.syncID, !trackKeys.contains(sid) else { continue }
            guard let id = track.id else { continue }
            try await store.deleteTrack(id: id)
            deleted += 1
        }
        return deleted
    }

    private static func artistId(for artistName: String?,
                                 artistKey: String?,
                                 artistKeyMap: [String: Int64],
                                 store: LibraryStore) async throws -> Int64? {
        if let artistKey, let id = artistKeyMap[artistKey] { return id }
        guard let artistName else { return nil }
        let artist = try await store.findOrCreateArtist(
            name: artistName,
            sortName: ArtistNamePolicy.sortName(for: artistName))
        return artist.id
    }

    private static func upsertRemoteAsset(forTrackId trackId: Int64,
                                          dto: WatchTrackDTO,
                                          store: LibraryStore) async throws {
        let remote = streamableURLString(dto.remoteURL)
        let alt = streamableURLString(dto.altRemoteURL)

        try await store.dbQueue.write { db in
            if var asset = try Asset
                .filter(Column("trackId") == trackId)
                .order(Column("id"))
                .fetchOne(db) {
                if remote == nil && alt == nil && asset.relPath == nil && asset.bookmark == nil {
                    if let id = asset.id {
                        try Asset.deleteOne(db, key: id)
                    }
                    return
                }
                asset.remoteURL = remote
                asset.altRemoteURL = alt
                asset.sizeBytes = dto.sizeBytes ?? asset.sizeBytes
                if asset.relPath == nil && asset.bookmark == nil {
                    asset.kind = .remote
                }
                try asset.update(db)
            } else {
                guard remote != nil || alt != nil else { return }
                var asset = Asset(
                    id: nil,
                    trackId: trackId,
                    kind: .remote,
                    bookmark: nil,
                    relPath: nil,
                    remoteURL: remote,
                    altRemoteURL: alt,
                    sizeBytes: dto.sizeBytes,
                    unsupportedReason: nil)
                try asset.insert(db)
            }
        }
    }

    private static func replaceManualPlaylist(dto: WatchPlaylistDTO,
                                              trackIds: [Int64],
                                              in store: LibraryStore) async throws {
        try await store.dbQueue.write { db in
            let bySyncID = try Playlist
                .filter(Column("syncID") == dto.key)
                .fetchOne(db)
            let legacyByTitle = try Playlist
                .filter(Column("syncID") == nil &&
                        Column("title") == dto.title &&
                        Column("kind") == PlaylistKind.manual.rawValue)
                .order(Column("id"))
                .fetchOne(db)

            let playlist: Playlist
            if var existing = bySyncID ?? legacyByTitle {
                existing.title = dto.title
                existing.kind = .manual
                existing.folderBookmark = nil
                existing.syncID = dto.key
                try existing.update(db)
                playlist = existing
            } else {
                var inserted = Playlist(
                    id: nil,
                    title: dto.title,
                    kind: .manual,
                    folderBookmark: nil,
                    watch: false,
                    syncID: dto.key)
                try inserted.insert(db)
                playlist = inserted
            }

            guard let playlistId = playlist.id else { return }
            try PlaylistItem
                .filter(Column("playlistId") == playlistId)
                .deleteAll(db)
            for (index, trackId) in trackIds.enumerated() {
                var item = PlaylistItem(
                    id: nil,
                    playlistId: playlistId,
                    position: index,
                    trackId: trackId,
                    sectionTitle: nil,
                    syncID: "\(dto.key)-\(index)-\(trackId)")
                try item.insert(db)
            }

            let duplicateLegacyIDs = try Playlist
                .filter(Column("syncID") == nil &&
                        Column("title") == dto.title &&
                        Column("kind") == PlaylistKind.manual.rawValue)
                .fetchAll(db)
                .compactMap(\.id)
            for id in duplicateLegacyIDs where id != playlistId {
                try Playlist.deleteOne(db, key: id)
            }
        }
    }

    private static func deleteStalePlaylists(importedKeys: Set<String>,
                                             in store: LibraryStore) async throws {
        try await store.dbQueue.write { db in
            let playlists = try Playlist
                .filter(Column("kind") == PlaylistKind.manual.rawValue)
                .fetchAll(db)
            for playlist in playlists {
                guard let syncID = playlist.syncID,
                      syncID.hasPrefix("p"),
                      !importedKeys.contains(syncID),
                      let id = playlist.id else { continue }
                try Playlist.deleteOne(db, key: id)
            }
        }
    }

    private static func streamableURLString(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url.absoluteString
    }

    private static func uniquePreservingOrder<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        var result: [T] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
