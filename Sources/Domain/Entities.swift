import Foundation

public enum SourceKind: String, Codable, CaseIterable {
    case local
    case iaItem
    case iaList
    case iaCollection
    case iaFavorites
    case subsonic
    case webDAV
    case smb
    case jellyfin
    case plex
    case dropbox
    case googleDrive
    case oneDrive
    case pCloud
}

public enum AssetKind: String, Codable {
    case localRef
    case managedCopy
    case remote
    case builtIn
}

public enum PlaylistKind: String, Codable {
    case manual
    case folder
}

public struct Source: Identifiable, Equatable, Codable, Hashable {
    public var id: Int64?
    public var kind: SourceKind
    public var iaIdentifier: String?
    public var originalURL: String?
    public var title: String
    public var addedAt: Date
    public var lastResolvedAt: Date?
    public var followUpdates: Bool
    public var licenseText: String?
    public var memberCapHit: Bool
    /// For `.local` sources: distinguishes a folder import (true) from the
    /// "Local Files" bucket (false). Drives the no-artwork fallback icon.
    public var localIsFolder: Bool = false
    /// Remembers which track's embedded artwork represents this source, so the
    /// representative cover is cached and stable across launches.
    public var artworkTrackId: Int64? = nil
    /// Stable cross-device identity for iCloud sync (schema v7). Local `Int64`
    /// PKs remain the internal FK join key; `syncID` names the CloudKit record.
    public var syncID: String? = nil

    /// SF Symbol shown over the gradient when no real artwork resolves.
    public var fallbackIcon: String {
        switch kind {
        case .local:
            return localIsFolder ? "folder.fill" : "music.note.list"
        case .iaList, .iaCollection, .iaFavorites:
            return "square.stack.fill"
        case .iaItem:
            return "music.note"
        case .subsonic, .jellyfin, .plex:
            return "server.rack"
        case .webDAV, .smb, .dropbox, .googleDrive, .oneDrive, .pCloud:
            return "externaldrive.connected.to.line.below"
        }
    }
}

public struct Album: Identifiable, Equatable, Codable {
    public var id: Int64?
    public var sourceId: Int64
    public var title: String
    public var artist: String?
    public var artistId: Int64? = nil
    public var albumArtist: String? = nil
    public var genre: String? = nil
    public var year: Int?
    public var artworkId: String?
    public var syncID: String? = nil
}

public struct Artist: Identifiable, Equatable, Codable, Hashable {
    public var id: Int64?
    public var name: String
    public var sortName: String
    public var syncID: String? = nil
}

public struct Track: Identifiable, Equatable, Codable {
    public var id: Int64?
    public var albumId: Int64?
    public var sourceId: Int64
    public var title: String
    public var trackNo: Int?
    public var discNo: Int?
    public var durationSec: Double?
    public var codec: String?
    public var sampleRate: Int?
    public var bitDepthOrBitrate: String?
    public var sortKey: String
    public var genre: String? = nil
    public var composer: String? = nil
    public var artistId: Int64? = nil
    public var rgTrackGain: Double? = nil
    public var rgAlbumGain: Double? = nil
    public var rgTrackPeak: Double? = nil
    public var rgAlbumPeak: Double? = nil
    public var syncID: String? = nil
}

public struct Asset: Identifiable, Equatable, Codable {
    public var id: Int64?
    public var trackId: Int64
    public var kind: AssetKind
    public var bookmark: Data?
    public var relPath: String?
    public var remoteURL: String?
    public var altRemoteURL: String?
    /// Opus derivative URL for this track, if the IA item offers one. Fetched and
    /// remuxed to CAF by the prefetcher so the next play upgrades to Opus (T2.4).
    public var opusRemoteURL: String? = nil
    public var sizeBytes: Int64?
    public var unsupportedReason: String?
    /// Set on a device where the asset's local file can't be resolved after an
    /// iCloud pull (the device-specific bookmark doesn't cross devices). The
    /// track shows greyed / "not on this device" until re-imported (C4).
    public var needsReimport: Bool = false
    public var syncID: String? = nil
    /// Runtime-only headers for browsed remote-library queue rows. Not persisted:
    /// credentials remain in the Keychain/provider layer.
    public var transientRemoteHeaders: [String: String] = [:]

    public enum CodingKeys: String, CodingKey {
        case id
        case trackId
        case kind
        case bookmark
        case relPath
        case remoteURL
        case altRemoteURL
        case opusRemoteURL
        case sizeBytes
        case unsupportedReason
        case needsReimport
        case syncID
    }
}

public struct CacheEntry: Identifiable, Equatable, Codable {
    public var id: Int64?
    public var assetId: Int64
    public var relPath: String
    public var totalBytes: Int64?
    public var byteRanges: Data
    public var complete: Bool
    public var lastAccessedAt: Date
    public var createdAt: Date
}

public struct Playlist: Identifiable, Equatable, Codable, Hashable {
    public var id: Int64?
    public var title: String
    public var kind: PlaylistKind
    public var folderBookmark: Data?
    public var watch: Bool
    public var syncID: String? = nil
}

public struct PlaylistItem: Identifiable, Equatable, Codable {
    public var id: Int64?
    public var playlistId: Int64
    public var position: Int
    public var trackId: Int64
    public var sectionTitle: String?
    public var syncID: String? = nil
}

public struct PlayEvent: Identifiable, Equatable, Codable {
    public var id: Int64?
    public var trackId: Int64
    public var playedAt: Date
    public var syncID: String? = nil
}

public struct Favorite: Identifiable, Equatable, Codable {
    public var id: Int64?
    public var trackId: Int64
    public var favoritedAt: Date
    public var syncID: String? = nil
}
