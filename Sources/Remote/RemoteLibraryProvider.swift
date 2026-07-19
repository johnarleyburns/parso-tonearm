import Foundation

public struct RemoteArtwork: Codable, Equatable, Hashable {
    public var id: String?
    public var url: URL?
    public var headers: [String: String]

    public init(id: String? = nil, url: URL? = nil, headers: [String: String] = [:]) {
        self.id = id
        self.url = url
        self.headers = headers
    }
}

public struct RemoteTrackMetadata: Codable, Equatable, Hashable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var durationSec: Double?
    public var codec: String?
    public var sampleRate: Int?
    public var bitRateKbps: Int?
    public var genre: String?
    public var artwork: RemoteArtwork?

    public init(title: String? = nil,
                artist: String? = nil,
                album: String? = nil,
                albumArtist: String? = nil,
                trackNumber: Int? = nil,
                discNumber: Int? = nil,
                durationSec: Double? = nil,
                codec: String? = nil,
                sampleRate: Int? = nil,
                bitRateKbps: Int? = nil,
                genre: String? = nil,
                artwork: RemoteArtwork? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.durationSec = durationSec
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitRateKbps = bitRateKbps
        self.genre = genre
        self.artwork = artwork
    }

    public var hasDisplayContext: Bool {
        [
            title, artist, album, albumArtist, codec, genre, artwork?.id, artwork?.url?.absoluteString,
        ].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } || trackNumber != nil || discNumber != nil || sampleRate != nil || bitRateKbps != nil
    }

    public func merged(overriding override: RemoteTrackMetadata?) -> RemoteTrackMetadata {
        guard let override else { return self }
        return RemoteTrackMetadata(
            title: override.title ?? title,
            artist: override.artist ?? artist,
            album: override.album ?? album,
            albumArtist: override.albumArtist ?? albumArtist,
            trackNumber: override.trackNumber ?? trackNumber,
            discNumber: override.discNumber ?? discNumber,
            durationSec: override.durationSec ?? durationSec,
            codec: override.codec ?? codec,
            sampleRate: override.sampleRate ?? sampleRate,
            bitRateKbps: override.bitRateKbps ?? bitRateKbps,
            genre: override.genre ?? genre,
            artwork: override.artwork ?? artwork
        )
    }
}

public struct RemoteNode: Identifiable, Codable, Equatable, Hashable {
    public enum Kind: String, Codable {
        case directory
        case audio
        case item
        case collection
    }

    public var id: String
    public var title: String
    public var path: String
    public var kind: Kind
    public var sizeBytes: Int64?
    public var durationSec: Double?
    public var metadata: RemoteTrackMetadata?

    public init(id: String,
         title: String,
         path: String,
         kind: Kind,
         sizeBytes: Int64? = nil,
         durationSec: Double? = nil,
         metadata: RemoteTrackMetadata? = nil) {
        self.id = id
        self.title = title
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.durationSec = durationSec
        self.metadata = metadata
    }
}

public struct ResolvedAsset: Codable, Equatable {
    public var url: URL
    public var headers: [String: String]
    public var supportsByteRanges: Bool
    public var sizeBytes: Int64?
    public var metadata: RemoteTrackMetadata?

    public init(url: URL,
         headers: [String: String] = [:],
         supportsByteRanges: Bool = true,
         sizeBytes: Int64? = nil,
         metadata: RemoteTrackMetadata? = nil) {
        self.url = url
        self.headers = headers
        self.supportsByteRanges = supportsByteRanges
        self.sizeBytes = sizeBytes
        self.metadata = metadata
    }
}

public protocol RemoteLibraryProvider {
    var sourceKind: SourceKind { get }

    func browse(path: String) async throws -> [RemoteNode]
    func resolve(node: RemoteNode) async throws -> ResolvedAsset
    func refresh() async throws
}

public struct RemoteLibraryStats: Equatable {
    public var artistCount: Int?
    public var albumCount: Int?
    public var folderCount: Int?
    public var trackCount: Int?
    public var totalBytes: Int64?

    public init(artistCount: Int? = nil,
                albumCount: Int? = nil,
                folderCount: Int? = nil,
                trackCount: Int? = nil,
                totalBytes: Int64? = nil) {
        self.artistCount = artistCount
        self.albumCount = albumCount
        self.folderCount = folderCount
        self.trackCount = trackCount
        self.totalBytes = totalBytes
    }

    public var formattedSummary: String {
        var parts: [String] = []
        if let c = trackCount { parts.append("\(c) tracks") }
        if let c = albumCount { parts.append("\(c) albums") }
        if let c = artistCount { parts.append("\(c) artists") }
        if let c = folderCount { parts.append("\(c) folders") }
        if let b = totalBytes, b > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))
        }
        return parts.isEmpty ? "No stats available" : parts.joined(separator: " · ")
    }
}
