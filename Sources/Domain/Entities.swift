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
    case builtIn
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
    /// For `.local` sources: distinguishes a folder import (true) from the
    /// "Local Files" bucket (false). Drives the no-artwork fallback icon.
    var localIsFolder: Bool = false
    /// Remembers which track's embedded artwork represents this source, so the
    /// representative cover is cached and stable across launches.
    var artworkTrackId: Int64? = nil

    /// SF Symbol shown over the gradient when no real artwork resolves.
    var fallbackIcon: String {
        switch kind {
        case .local:
            return localIsFolder ? "folder.fill" : "music.note.list"
        case .iaList, .iaCollection, .iaFavorites:
            return "square.stack.fill"
        case .iaItem:
            return "music.note"
        }
    }
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
    var altRemoteURL: String?
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
