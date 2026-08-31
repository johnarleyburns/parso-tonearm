import Foundation
import SwiftData

public enum WatchAssetValidationState: String, Codable, Sendable { case installing, ready, corrupt, pendingDeletion }
public enum WatchDownloadJobState: String, Codable, Sendable { case queued, transferring, received, installing, ready, failed, cancelled }
public enum WatchDownloadRootKind: String, Codable, Sendable { case track, playlist, albumBatch }

@Model public final class WatchTrackModel {
    @Attribute(.unique) public var trackID: String
    public var title: String
    public var normalizedTitle: String
    public var artist: String
    public var normalizedArtist: String
    public var albumTitle: String
    public var normalizedAlbum: String
    public var durationSeconds: Double?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var artworkID: String?
    public var coverArtworkID: String?
    public var customArtworkID: String?
    public var localThumbnailFilename: String?
    public var codec: String?
    public var expectedBytes: Int64?
    public var expectedSHA256: String?
    public var phoneRevision: Int64
    public var metadataUpdatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \WatchAssetModel.track) public var asset: WatchAssetModel?

    public init(trackID: String, title: String, artist: String = "", albumTitle: String = "",
                durationSeconds: Double? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
                artworkID: String? = nil, coverArtworkID: String? = nil, customArtworkID: String? = nil,
                localThumbnailFilename: String? = nil, codec: String? = nil,
                expectedBytes: Int64? = nil, expectedSHA256: String? = nil, phoneRevision: Int64 = 0,
                metadataUpdatedAt: Date = Date()) {
        self.trackID = trackID; self.title = title; normalizedTitle = WatchTextNormalizer.normalize(title)
        self.artist = artist; normalizedArtist = WatchTextNormalizer.normalize(artist)
        self.albumTitle = albumTitle; normalizedAlbum = WatchTextNormalizer.normalize(albumTitle)
        self.durationSeconds = durationSeconds; self.trackNumber = trackNumber; self.discNumber = discNumber
        self.artworkID = artworkID; self.coverArtworkID = coverArtworkID ?? artworkID
        self.customArtworkID = customArtworkID; self.localThumbnailFilename = localThumbnailFilename; self.codec = codec
        self.expectedBytes = expectedBytes; self.expectedSHA256 = expectedSHA256
        self.phoneRevision = phoneRevision; self.metadataUpdatedAt = metadataUpdatedAt
    }
}

@Model public final class WatchArtworkAssetModel {
    @Attribute(.unique) public var artworkID: String
    public var relativeFilename: String
    public var bytes: Int64
    public var installedAt: Date
    public var validationStateRaw: String
    public var validationState: WatchAssetValidationState {
        get { WatchAssetValidationState(rawValue: validationStateRaw) ?? .corrupt }
        set { validationStateRaw = newValue.rawValue }
    }
    public init(artworkID: String, relativeFilename: String, bytes: Int64,
                installedAt: Date = Date(), validationState: WatchAssetValidationState) {
        self.artworkID = artworkID; self.relativeFilename = relativeFilename; self.bytes = bytes
        self.installedAt = installedAt; self.validationStateRaw = validationState.rawValue
    }
}

@Model public final class WatchAssetModel {
    @Attribute(.unique) public var trackID: String
    public var relativeFilename: String
    public var installedBytes: Int64
    public var sha256: String
    public var installedAt: Date
    public var validationStateRaw: String
    public var track: WatchTrackModel?
    public var validationState: WatchAssetValidationState {
        get { WatchAssetValidationState(rawValue: validationStateRaw) ?? .corrupt }
        set { validationStateRaw = newValue.rawValue }
    }
    public init(trackID: String, relativeFilename: String, installedBytes: Int64, sha256: String,
                installedAt: Date = Date(), validationState: WatchAssetValidationState) {
        self.trackID = trackID; self.relativeFilename = relativeFilename; self.installedBytes = installedBytes
        self.sha256 = sha256; self.installedAt = installedAt; validationStateRaw = validationState.rawValue
    }
}

@Model public final class WatchPlaylistModel {
    @Attribute(.unique) public var playlistID: String
    public var title: String
    public var normalizedTitle: String
    public var phoneRevision: Int64
    public var desiredOnWatch: Bool
    public var lastReconciledAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \WatchPlaylistEntryModel.playlist) public var entries: [WatchPlaylistEntryModel]
    public init(playlistID: String, title: String, phoneRevision: Int64 = 0, desiredOnWatch: Bool = false,
                lastReconciledAt: Date? = nil, entries: [WatchPlaylistEntryModel] = []) {
        self.playlistID = playlistID; self.title = title; normalizedTitle = WatchTextNormalizer.normalize(title)
        self.phoneRevision = phoneRevision; self.desiredOnWatch = desiredOnWatch
        self.lastReconciledAt = lastReconciledAt; self.entries = entries
    }
}

@Model public final class WatchPlaylistEntryModel {
    @Attribute(.unique) public var entryID: String
    public var trackID: String
    public var ordinal: Int
    public var playlist: WatchPlaylistModel?
    public init(entryID: String, trackID: String, ordinal: Int) {
        self.entryID = entryID; self.trackID = trackID; self.ordinal = ordinal
    }
}

@Model public final class WatchDownloadJobModel {
    @Attribute(.unique) public var requestID: String
    public var trackID: String
    public var rootIDs: [String]
    public var stateRaw: String
    public var expectedBytes: Int64?
    public var expectedSHA256: String?
    public var attemptCount: Int
    public var attemptToken: String
    public var errorCode: String?
    public var safeUserMessage: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var state: WatchDownloadJobState {
        get { WatchDownloadJobState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }
    public init(requestID: String, trackID: String, rootIDs: [String], state: WatchDownloadJobState = .queued,
                expectedBytes: Int64? = nil, expectedSHA256: String? = nil, attemptCount: Int = 1,
                attemptToken: String, errorCode: String? = nil, safeUserMessage: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.requestID = requestID; self.trackID = trackID; self.rootIDs = rootIDs; stateRaw = state.rawValue
        self.expectedBytes = expectedBytes; self.expectedSHA256 = expectedSHA256; self.attemptCount = attemptCount
        self.attemptToken = attemptToken; self.errorCode = errorCode; self.safeUserMessage = safeUserMessage
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

@Model public final class WatchDownloadRootModel {
    @Attribute(.unique) public var rootID: String
    public var kindRaw: String
    public var sourceID: String
    public var desiredTrackIDs: [String]
    public var phoneRevision: Int64
    public var createdAt: Date
    public var kind: WatchDownloadRootKind {
        get { WatchDownloadRootKind(rawValue: kindRaw) ?? .track }
        set { kindRaw = newValue.rawValue }
    }
    public init(rootID: String, kind: WatchDownloadRootKind, sourceID: String, desiredTrackIDs: [String],
                phoneRevision: Int64 = 0, createdAt: Date = Date()) {
        self.rootID = rootID; kindRaw = kind.rawValue; self.sourceID = sourceID
        self.desiredTrackIDs = desiredTrackIDs; self.phoneRevision = phoneRevision; self.createdAt = createdAt
    }
}

@Model public final class WatchPlaybackStateModel {
    @Attribute(.unique) public var stateID: String
    public var queueTrackIDs: [String]
    public var currentIndex: Int
    public var elapsedSeconds: Double
    public var shuffleEnabled: Bool
    public var repeatMode: String
    public var updatedAt: Date
    public init(stateID: String = "local", queueTrackIDs: [String], currentIndex: Int = 0,
                elapsedSeconds: Double = 0, shuffleEnabled: Bool = false, repeatMode: String = "off",
                updatedAt: Date = Date()) {
        self.stateID = stateID; self.queueTrackIDs = queueTrackIDs; self.currentIndex = currentIndex
        self.elapsedSeconds = elapsedSeconds; self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode; self.updatedAt = updatedAt
    }
}

@Model public final class WatchSyncStateModel {
    @Attribute(.unique) public var stateID: String
    public var protocolVersion: Int
    public var pairedLibraryIdentity: String?
    public var lastAppliedPhoneRevision: Int64
    public var lastManifestID: String?
    public var lastConnectionAt: Date?
    public var lastSuccessfulSyncAt: Date?
    public init(stateID: String = "primary", protocolVersion: Int, pairedLibraryIdentity: String? = nil,
                lastAppliedPhoneRevision: Int64 = 0, lastManifestID: String? = nil,
                lastConnectionAt: Date? = nil, lastSuccessfulSyncAt: Date? = nil) {
        self.stateID = stateID; self.protocolVersion = protocolVersion
        self.pairedLibraryIdentity = pairedLibraryIdentity; self.lastAppliedPhoneRevision = lastAppliedPhoneRevision
        self.lastManifestID = lastManifestID; self.lastConnectionAt = lastConnectionAt
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    }
}

public enum WatchTextNormalizer {
    public static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
