import CryptoKit
import Foundation

/// Every value crossing the repository boundary is a `Sendable` snapshot. SwiftData models are
/// never handed to another actor; see §4 of the watch re-architecture plan.

public struct WatchTrackUpsert: Hashable, Sendable {
    public let trackID: String
    public let title: String
    public let artist: String
    public let albumTitle: String
    public let durationSeconds: Double?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let artworkID: String?
    public let coverArtworkID: String?
    public let customArtworkID: String?
    public let localThumbnailFilename: String?
    public let codec: String?
    public let expectedBytes: Int64?
    public let expectedSHA256: String?
    public let phoneRevision: Int64

    public init(trackID: String, title: String, artist: String = "", albumTitle: String = "",
                durationSeconds: Double? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
                artworkID: String? = nil, coverArtworkID: String? = nil,
                customArtworkID: String? = nil, localThumbnailFilename: String? = nil, codec: String? = nil,
                expectedBytes: Int64? = nil, expectedSHA256: String? = nil, phoneRevision: Int64 = 0) {
        self.trackID = trackID; self.title = title; self.artist = artist; self.albumTitle = albumTitle
        self.durationSeconds = durationSeconds; self.trackNumber = trackNumber; self.discNumber = discNumber
        self.artworkID = artworkID; self.coverArtworkID = coverArtworkID
        self.customArtworkID = customArtworkID; self.localThumbnailFilename = localThumbnailFilename; self.codec = codec
        self.expectedBytes = expectedBytes; self.expectedSHA256 = expectedSHA256; self.phoneRevision = phoneRevision
    }
}

public struct WatchPlaylistUpsert: Hashable, Sendable {
    public let playlistID: String
    public let title: String
    public let trackIDs: [String]
    public let phoneRevision: Int64

    public init(playlistID: String, title: String, trackIDs: [String], phoneRevision: Int64 = 0) {
        self.playlistID = playlistID; self.title = title
        self.trackIDs = trackIDs; self.phoneRevision = phoneRevision
    }
}

/// §5.4: a stale revision is acknowledged but not applied, so callers can still reply.
public enum WatchUpsertOutcome: String, Equatable, Sendable { case inserted, updated, staleIgnored }

public struct WatchTrackSnapshot: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let albumTitle: String
    public let durationSeconds: Double?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let artworkID: String?
    public let codec: String?
    public let phoneRevision: Int64
    public let localFilename: String?
    public let isReady: Bool
}

public struct WatchPlaylistSnapshot: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let trackIDs: [String]
    public let readyTrackIDs: [String]
    public var isPartial: Bool { readyTrackIDs.count != trackIDs.count }
}

public struct WatchManifestSnapshot: Equatable, Sendable {
    public let manifestID: String
    public let readyTrackIDs: [String]
    public let installedBytes: Int64
}

public struct WatchStorageSnapshot: Equatable, Sendable {
    public let readyBytes: Int64
    public let stagingBytes: Int64
    public let orphanBytes: Int64
    public let freeBytes: Int64
    public let capacityBytes: Int64

    /// §2.5: reserve the greater of 500 MB or 10% of reported free capacity before accepting a batch.
    public static let minimumReserveBytes: Int64 = 500 * 1_000_000
    public var reserveBytes: Int64 { max(Self.minimumReserveBytes, freeBytes / 10) }
    public func canAccept(bytes: Int64) -> Bool { bytes >= 0 && freeBytes - bytes >= reserveBytes }

    public init(readyBytes: Int64, stagingBytes: Int64, orphanBytes: Int64,
                freeBytes: Int64 = 0, capacityBytes: Int64 = 0) {
        self.readyBytes = readyBytes; self.stagingBytes = stagingBytes; self.orphanBytes = orphanBytes
        self.freeBytes = freeBytes; self.capacityBytes = capacityBytes
    }
}

/// A file found on disk with no database row, already hashed by reconciliation and therefore
/// adoptable. Contrast `WatchRecoverableFileSnapshot`, which is the cheap launch-time scan.
public struct WatchOrphanSnapshot: Identifiable, Hashable, Sendable {
    public var id: String { relativeFilename }
    public let relativeFilename: String
    public let bytes: Int64
    public let sha256: String

    public init(relativeFilename: String, bytes: Int64, sha256: String) {
        self.relativeFilename = relativeFilename; self.bytes = bytes; self.sha256 = sha256
    }
}

/// Audio retained across a store rebuild. Deliberately carries no checksum: hashing every file
/// would block launch, and a placeholder digest would be a lie.
public struct WatchRecoverableFileSnapshot: Identifiable, Hashable, Sendable {
    public var id: String { relativeFilename }
    public let relativeFilename: String
    public let bytes: Int64

    public init(relativeFilename: String, bytes: Int64) {
        self.relativeFilename = relativeFilename; self.bytes = bytes
    }
}

public struct WatchReconciliationSnapshot: Equatable, Sendable {
    public let missingTrackIDs: [String]
    public let corruptTrackIDs: [String]
    public let orphans: [WatchOrphanSnapshot]
}

public struct WatchPlaybackSnapshot: Equatable, Sendable {
    public let queueTrackIDs: [String]
    public let currentIndex: Int
    public let elapsedSeconds: Double
    public let shuffleEnabled: Bool
    public let repeatMode: String
}

public enum WatchLibraryError: Error, Equatable { case unknownTrack(String), invalidOrphan(String) }

/// Chunked hashing: watch audio files are read a block at a time so a large track never has to be
/// resident in memory to be validated.
public enum WatchFileDigest {
    public static let chunkBytes = 256 * 1024

    public static func measure(_ url: URL) throws -> (sha256: String, bytes: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        return (hex(hasher.finalize()), total)
    }

    public static func hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
