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
        let allAlbums = try await store.allAlbums()
        let allPlaylists = try await store.allPlaylists()
        let allArtists = try await store.allArtists()

        let artistMap = Dictionary(uniqueKeysWithValues: allArtists.compactMap { a -> (Int64, Artist)? in
            guard let id = a.id else { return nil }
            return (id, a)
        })
        let albumIDs = Set(allAlbums.compactMap(\.id))

        let albumDTOs: [WatchAlbumDTO] = allAlbums.compactMap { album in
            guard let id = album.id else { return nil }
            return WatchAlbumDTO(
                key: albumKey(for: id),
                title: album.title,
                artist: album.artist ?? album.albumArtist,
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
            if let artistId = track.artistId, let a = artistMap[artistId] {
                artist = a.name
            }
            return WatchTrackDTO(
                key: key(for: id),
                title: track.title,
                artist: artist,
                albumKey: aKey,
                durationSec: track.durationSec,
                codec: track.codec,
                sizeBytes: nil,
                trackNo: track.trackNo,
                discNo: track.discNo,
                sortKey: track.sortKey)
        }

        var playlistDTOs: [WatchPlaylistDTO] = []
        for playlist in allPlaylists {
            guard let pid = playlist.id else { continue }
            let items: [String] = ((try? await store.playlistTrackRows(playlistId: pid))?.compactMap { ptr in
                guard let tid = ptr.row.track.id else { return nil }
                return key(for: tid)
            }) ?? []
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
        var src = Source(
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
            let artistId = dto.artist != nil ? artistKeyMap[dto.key] : nil
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
            let artistId = dto.artist != nil ? artistKeyMap[dto.key] : nil

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
                if let id = track.id { map[dto.key] = id }
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
                if let id = track.id { map[dto.key] = id }
            }
        }
        return map
    }

    private static func upsertPlaylists(_ dtos: [WatchPlaylistDTO],
                                         trackKeyMap: [String: Int64],
                                         into store: LibraryStore,
                                         result: inout ImportResult) async throws {
        let existing = try await store.allPlaylists()
        for dto in dtos {
            let trackIds = dto.trackKeys.compactMap { trackKeyMap[$0] }
            if let pl = existing.first(where: { $0.title == dto.title && $0.kind == .manual }),
               let plId = pl.id {
                _ = try await store.deletePlaylist(id: plId)
            }
            _ = try await store.createManualPlaylist(title: dto.title, trackIds: trackIds)
            result.upsertedPlaylists += 1
        }
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
}
