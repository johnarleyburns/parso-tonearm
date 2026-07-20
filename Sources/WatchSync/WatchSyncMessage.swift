import Foundation

public enum WatchSyncMessageKind: String, Codable {
    case catalog
    case artwork
    case audio
    case deleteTracks
    case manifestReport
    case fetchRequest
    case fetchCancel
    case resendCatalog
}

public struct WatchSyncEnvelope: Codable, Equatable {
    public var protocolVersion: Int
    public var catalogVersion: Int
    public var kind: WatchSyncMessageKind
    public var payload: Data

    public init(protocolVersion: Int, catalogVersion: Int,
                kind: WatchSyncMessageKind, payload: Data) {
        self.protocolVersion = protocolVersion
        self.catalogVersion = catalogVersion
        self.kind = kind
        self.payload = payload
    }

    public static let currentProtocolVersion = 1

    public static func encode<Payload: Codable>(kind: WatchSyncMessageKind,
                                                 catalogVersion: Int,
                                                 payload: Payload) throws -> Data {
        let payloadData = try JSONEncoder().encode(payload)
        let envelope = WatchSyncEnvelope(
            protocolVersion: currentProtocolVersion,
            catalogVersion: catalogVersion,
            kind: kind,
            payload: payloadData)
        return try JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) -> WatchSyncEnvelope? {
        try? JSONDecoder().decode(WatchSyncEnvelope.self, from: data)
    }

    public func decodePayload<Payload: Codable>(_ type: Payload.Type) -> Payload? {
        try? JSONDecoder().decode(type, from: payload)
    }
}

// MARK: - Payload types

public struct WatchCatalogSnapshot: Codable, Equatable {
    public var version: Int
    public var playlists: [WatchPlaylistDTO]
    public var albums: [WatchAlbumDTO]
    public var artists: [WatchArtistDTO]
    public var tracks: [WatchTrackDTO]

    public init(version: Int, playlists: [WatchPlaylistDTO], albums: [WatchAlbumDTO],
                artists: [WatchArtistDTO], tracks: [WatchTrackDTO]) {
        self.version = version
        self.playlists = playlists
        self.albums = albums
        self.artists = artists
        self.tracks = tracks
    }
}

public struct WatchTrackDTO: Codable, Equatable {
    public var key: String
    public var title: String
    public var artist: String?
    public var albumKey: String?
    public var durationSec: Double?
    public var codec: String?
    public var sizeBytes: Int64?
    public var trackNo: Int?
    public var discNo: Int?
    public var sortKey: String

    public init(key: String, title: String, artist: String? = nil,
                albumKey: String? = nil, durationSec: Double? = nil,
                codec: String? = nil, sizeBytes: Int64? = nil,
                trackNo: Int? = nil, discNo: Int? = nil,
                sortKey: String) {
        self.key = key
        self.title = title
        self.artist = artist
        self.albumKey = albumKey
        self.durationSec = durationSec
        self.codec = codec
        self.sizeBytes = sizeBytes
        self.trackNo = trackNo
        self.discNo = discNo
        self.sortKey = sortKey
    }
}

public struct WatchAlbumDTO: Codable, Equatable {
    public var key: String
    public var title: String
    public var artist: String?
    public var artworkId: String?
    public var year: Int?

    public init(key: String, title: String, artist: String? = nil,
                artworkId: String? = nil, year: Int? = nil) {
        self.key = key
        self.title = title
        self.artist = artist
        self.artworkId = artworkId
        self.year = year
    }
}

public struct WatchPlaylistDTO: Codable, Equatable {
    public var key: String
    public var title: String
    public var trackKeys: [String]

    public init(key: String, title: String, trackKeys: [String]) {
        self.key = key
        self.title = title
        self.trackKeys = trackKeys
    }
}

public struct WatchArtistDTO: Codable, Equatable {
    public var key: String
    public var name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

public struct WatchAudioMetadata: Codable, Equatable {
    public var trackKey: String
    public var bytes: Int64
    public var pinned: Bool
    public var catalogVersion: Int

    public init(trackKey: String, bytes: Int64, pinned: Bool, catalogVersion: Int) {
        self.trackKey = trackKey
        self.bytes = bytes
        self.pinned = pinned
        self.catalogVersion = catalogVersion
    }
}

public struct WatchManifestReport: Codable, Equatable {
    public var entries: [WatchSyncManifestEntry]
    public var freeBytes: Int64
    public var catalogVersion: Int

    public init(entries: [WatchSyncManifestEntry], freeBytes: Int64, catalogVersion: Int) {
        self.entries = entries
        self.freeBytes = freeBytes
        self.catalogVersion = catalogVersion
    }
}

public struct WatchSyncManifestEntry: Codable, Equatable {
    public var trackKey: String
    public var bytes: Int64
    public var pinned: Bool

    public init(trackKey: String, bytes: Int64, pinned: Bool) {
        self.trackKey = trackKey
        self.bytes = bytes
        self.pinned = pinned
    }
}

public struct WatchFetchRequest: Codable, Equatable {
    public var trackKey: String

    public init(trackKey: String) {
        self.trackKey = trackKey
    }
}

public struct WatchDeleteTracks: Codable, Equatable {
    public var trackKeys: [String]

    public init(trackKeys: [String]) {
        self.trackKeys = trackKeys
    }
}
