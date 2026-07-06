import Foundation

enum SourceKind: String, Codable, CaseIterable {
    case local
    case iaItem
    case iaList
    case iaCollection
    case iaFavorites
}

enum AssetKind: String, Codable {
    case localRef
    case managedCopy
    case remote
}

enum PlaylistKind: String, Codable {
    case manual
    case folder
}

struct Source: Identifiable, Equatable, Codable, Hashable {
    var id: Int64?
    var kind: SourceKind
    var iaIdentifier: String?
    var originalURL: String?
    var title: String
    var addedAt: Date
    var lastResolvedAt: Date?
    var followUpdates: Bool
    var licenseText: String?
    var memberCapHit: Bool
}

struct Album: Identifiable, Equatable, Codable {
    var id: Int64?
    var sourceId: Int64
    var title: String
    var artist: String?
    var year: Int?
    var artworkId: String?
}

struct Track: Identifiable, Equatable, Codable {
    var id: Int64?
    var albumId: Int64?
    var sourceId: Int64
    var title: String
    var trackNo: Int?
    var discNo: Int?
    var durationSec: Double?
    var codec: String?
    var sampleRate: Int?
    var bitDepthOrBitrate: String?
    var sortKey: String
}

struct Asset: Identifiable, Equatable, Codable {
    var id: Int64?
    var trackId: Int64
    var kind: AssetKind
    var bookmark: Data?
    var relPath: String?
    var remoteURL: String?
    var sizeBytes: Int64?
    var unsupportedReason: String?
}

struct CacheEntry: Identifiable, Equatable, Codable {
    var id: Int64?
    var assetId: Int64
    var relPath: String
    var totalBytes: Int64?
    var byteRanges: Data
    var complete: Bool
    var lastAccessedAt: Date
    var createdAt: Date
}

struct Playlist: Identifiable, Equatable, Codable, Hashable {
    var id: Int64?
    var title: String
    var kind: PlaylistKind
    var folderBookmark: Data?
    var watch: Bool
}

struct PlaylistItem: Identifiable, Equatable, Codable {
    var id: Int64?
    var playlistId: Int64
    var position: Int
    var trackId: Int64
    var sectionTitle: String?
}

struct PlayEvent: Identifiable, Equatable, Codable {
    var id: Int64?
    var trackId: Int64
    var playedAt: Date
}

struct Favorite: Identifiable, Equatable, Codable {
    var id: Int64?
    var trackId: Int64
    var favoritedAt: Date
}
