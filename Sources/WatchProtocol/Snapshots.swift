import Foundation

/// The compact track DTO every paged response is built from. §5.2 forbids serializing the complete
/// phone catalog, so this carries what a watch row draws and nothing else — no file URL, no source
/// identity, no credential-bearing remote address.
public struct WatchTrackSummary: Codable, Equatable, Sendable, Identifiable {
    public var trackID: WatchTrackID
    public var title: String
    public var artist: String
    public var albumTitle: String
    public var durationSeconds: Double?
    public var artworkID: String?
    public var coverArtworkID: String?
    public var customArtworkID: String?
    public var isDownloadedOnWatch: Bool

    public var id: WatchTrackID { trackID }

    public init(trackID: WatchTrackID, title: String, artist: String = "", albumTitle: String = "",
                durationSeconds: Double? = nil, artworkID: String? = nil,
                coverArtworkID: String? = nil, customArtworkID: String? = nil,
                isDownloadedOnWatch: Bool = false) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.durationSeconds = durationSeconds
        self.artworkID = artworkID
        self.coverArtworkID = coverArtworkID
        self.customArtworkID = customArtworkID
        self.isDownloadedOnWatch = isDownloadedOnWatch
    }
}

/// A playlist's metadata and membership in the watch-local catalog. Audio readiness is deliberately
/// not carried here; the watch derives that from its validated local asset.
public struct WatchLibraryPlaylist: Codable, Equatable, Sendable, Identifiable {
    public let playlistID: String
    public let title: String
    public let trackIDs: [WatchTrackID]
    public var id: String { playlistID }

    public init(playlistID: String, title: String, trackIDs: [WatchTrackID]) {
        self.playlistID = playlistID
        self.title = title
        self.trackIDs = trackIDs
    }
}

/// Chunk of the complete My Music catalog. The watch assembles all pages before applying them so a
/// reconnect cannot expose a half-updated searchable library.
public struct WatchLibraryPage: Codable, Equatable, Sendable {
    public let catalogID: String
    public let revision: Int64
    public let pageIndex: Int
    public let pageCount: Int
    public let tracks: [WatchTrackSummary]
    public let playlists: [WatchLibraryPlaylist]

    public init(catalogID: String, revision: Int64, pageIndex: Int, pageCount: Int,
                tracks: [WatchTrackSummary], playlists: [WatchLibraryPlaylist]) {
        self.catalogID = catalogID
        self.revision = revision
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.tracks = tracks
        self.playlists = playlists
    }
}

public enum WatchRepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one
}

/// Where the phone's current audio comes from. The watch uses this only to explain itself; it never
/// resolves a source (§14: no watch code contacts a remote provider).
public enum WatchPlaybackSourceKind: String, Codable, Sendable, CaseIterable {
    case none, localLibrary, remoteSource, dj
}

/// §5.3 `phonePlaybackSnapshot`. The elapsed position is an *anchor plus a rate*, not a ticking
/// number: a snapshot that crosses the link is already stale, and a watch that extrapolates from
/// `elapsedAnchorDate` stays correct without the phone streaming it a clock.
public struct WatchPhonePlaybackSnapshot: Codable, Equatable, Sendable {
    public var revision: Int64
    public var source: WatchPlaybackSourceKind
    public var isPlaying: Bool
    public var rate: Double
    public var currentItem: WatchTrackSummary?
    public var collection: WatchCollectionRef?
    public var collectionTitle: String?
    /// A bounded window around the current index — never the whole queue.
    public var queueWindow: [WatchTrackSummary]
    public var queueWindowStartIndex: Int
    public var queueIndex: Int
    public var queueCount: Int
    public var elapsedSeconds: Double
    public var elapsedAnchorDate: Date
    public var shuffleEnabled: Bool
    public var repeatMode: WatchRepeatMode
    /// The phone player's own output level (0...1), so the watch Crown starts from the real value.
    /// `nil` from a phone that predates the watch redesign.
    public var volume: Double?
    /// Average colour of the current item's artwork as `#RRGGBB`, computed on the phone so the
    /// watch can tint Now Playing without receiving the image. `nil` when there is no artwork.
    public var artworkColorHex: String?

    public static let queueWindowLimit = 20

    public init(revision: Int64, source: WatchPlaybackSourceKind = .none, isPlaying: Bool = false,
                rate: Double = 0, currentItem: WatchTrackSummary? = nil,
                collection: WatchCollectionRef? = nil, collectionTitle: String? = nil,
                queueWindow: [WatchTrackSummary] = [], queueWindowStartIndex: Int = 0,
                queueIndex: Int = 0, queueCount: Int = 0, elapsedSeconds: Double = 0,
                elapsedAnchorDate: Date = Date(), shuffleEnabled: Bool = false,
                repeatMode: WatchRepeatMode = .off, volume: Double? = nil,
                artworkColorHex: String? = nil) {
        self.revision = revision
        self.source = source
        self.isPlaying = isPlaying
        self.rate = rate
        self.currentItem = currentItem
        self.collection = collection
        self.collectionTitle = collectionTitle
        self.queueWindow = queueWindow
        self.queueWindowStartIndex = queueWindowStartIndex
        self.queueIndex = queueIndex
        self.queueCount = queueCount
        self.elapsedSeconds = elapsedSeconds
        self.elapsedAnchorDate = elapsedAnchorDate
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
        self.volume = volume
        self.artworkColorHex = artworkColorHex
    }

    /// Elapsed position projected forward from the anchor. Clamped to the item duration so a
    /// snapshot that arrives after the track ended cannot render past the end.
    public func elapsedSeconds(at date: Date) -> Double {
        guard isPlaying, rate > 0 else { return elapsedSeconds }
        let projected = elapsedSeconds + date.timeIntervalSince(elapsedAnchorDate) * rate
        guard let duration = currentItem?.durationSeconds, duration > 0 else { return max(0, projected) }
        return min(max(0, projected), duration)
    }
}

/// §5.3 `downloadStatusSnapshot`. Counts and states only — E-13 forbids fabricating incoming byte
/// progress on the watch, so no byte counter appears here.
/// Per-track transfer progress the phone can observe from its own `WCSession.outstandingFileTransfers`
/// and forward. E-13: the watch renders it but never invents it — an empty list means "no number to
/// show", and the UI falls back to a state indicator.
public struct WatchTransferProgress: Codable, Equatable, Sendable {
    public var trackID: WatchTrackID
    public var fractionComplete: Double

    public init(trackID: WatchTrackID, fractionComplete: Double) {
        self.trackID = trackID
        self.fractionComplete = min(1, max(0, fractionComplete))
    }
}

/// Watch redesign D1 — one download root (a playlist, album or single track) as the watch shows it
/// on "On This Watch": what it is, how far along, and the specific reason it is waiting.
public struct WatchDownloadRootStatus: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case downloading, queued, waitingForWiFi, paused, failed, complete
    }

    public var rootID: String
    public var title: String
    public var desiredCount: Int
    public var readyCount: Int
    public var failedCount: Int
    public var state: State

    public var id: String { rootID }

    public init(rootID: String, title: String, desiredCount: Int, readyCount: Int,
                failedCount: Int = 0, state: State) {
        self.rootID = rootID
        self.title = title
        self.desiredCount = desiredCount
        self.readyCount = readyCount
        self.failedCount = failedCount
        self.state = state
    }

    public var fraction: Double {
        desiredCount > 0 ? min(1, Double(readyCount) / Double(desiredCount)) : 1
    }
}

public struct WatchDownloadActivity: Codable, Equatable, Sendable, Identifiable {
    public enum Stage: String, Codable, Sendable {
        case queued, preparing, waitingForDelivery, transferring, awaitingInstallation
        case waitingForWiFi, failed, paused
    }
    public var trackID: WatchTrackID
    public var title: String
    public var stage: Stage
    public var fractionComplete: Double?
    public var message: String?
    public var id: String { trackID.rawValue }

    public init(trackID: WatchTrackID, title: String = "", stage: Stage,
                fractionComplete: Double? = nil, message: String? = nil) {
        self.trackID = trackID; self.title = title; self.stage = stage
        self.fractionComplete = fractionComplete; self.message = message
    }
}

public struct WatchDownloadStatusSnapshot: Codable, Equatable, Sendable {
    public var revision: Int64
    public var queuedCount: Int
    public var activeCount: Int
    public var waitingForWiFiCount: Int
    public var failedCount: Int
    public var readyCount: Int
    /// Sender-side byte progress for the transfers in flight right now. Optional on the wire —
    /// an older phone omits it and the watch shows a state indicator instead.
    public var activeTransfers: [WatchTransferProgress]
    /// Watch redesign D1: per-root progress and state. Empty from an older phone.
    public var roots: [WatchDownloadRootStatus]
    public var activities: [WatchDownloadActivity]
    public var generatedAt: Date?
    public var lastWatchReportAt: Date?

    public init(revision: Int64, queuedCount: Int = 0, activeCount: Int = 0,
                waitingForWiFiCount: Int = 0, failedCount: Int = 0, readyCount: Int = 0,
                activeTransfers: [WatchTransferProgress] = [], roots: [WatchDownloadRootStatus] = [],
                activities: [WatchDownloadActivity] = [], generatedAt: Date? = nil,
                lastWatchReportAt: Date? = nil) {
        self.revision = revision
        self.queuedCount = queuedCount
        self.activeCount = activeCount
        self.waitingForWiFiCount = waitingForWiFiCount
        self.failedCount = failedCount
        self.readyCount = readyCount
        self.activeTransfers = activeTransfers
        self.roots = roots
        self.activities = activities
        self.generatedAt = generatedAt
        self.lastWatchReportAt = lastWatchReportAt
    }

    private enum CodingKeys: String, CodingKey {
        case revision, queuedCount, activeCount, waitingForWiFiCount, failedCount, readyCount, activeTransfers
        case roots, activities, generatedAt, lastWatchReportAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(Int64.self, forKey: .revision)
        queuedCount = try c.decodeIfPresent(Int.self, forKey: .queuedCount) ?? 0
        activeCount = try c.decodeIfPresent(Int.self, forKey: .activeCount) ?? 0
        waitingForWiFiCount = try c.decodeIfPresent(Int.self, forKey: .waitingForWiFiCount) ?? 0
        failedCount = try c.decodeIfPresent(Int.self, forKey: .failedCount) ?? 0
        readyCount = try c.decodeIfPresent(Int.self, forKey: .readyCount) ?? 0
        activeTransfers = try c.decodeIfPresent([WatchTransferProgress].self, forKey: .activeTransfers) ?? []
        roots = try c.decodeIfPresent([WatchDownloadRootStatus].self, forKey: .roots) ?? []
        activities = try c.decodeIfPresent([WatchDownloadActivity].self, forKey: .activities) ?? []
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
        lastWatchReportAt = try c.decodeIfPresent(Date.self, forKey: .lastWatchReportAt)
    }

    public var isIdle: Bool {
        queuedCount == 0 && activeCount == 0 && waitingForWiFiCount == 0
            && !activities.contains { $0.stage != .failed && $0.stage != .paused }
    }

    public func fraction(for trackID: WatchTrackID) -> Double? {
        activeTransfers.first { $0.trackID == trackID }?.fractionComplete
    }
}

/// §5.3 `watchManifest` — the watch's *actual* state, which §1.6 makes the second authority: the
/// phone owns what should be downloaded, the watch owns what is.
public struct WatchManifestPayload: Codable, Equatable, Sendable {
    public var manifestID: String
    public var readyTrackIDs: [WatchTrackID]
    public var installedBytes: Int64
    public var capacityBytes: Int64
    public var freeBytes: Int64
    public var installedArtworkIDs: [String]
    public var generatedAt: Date

    public init(manifestID: String, readyTrackIDs: [WatchTrackID], installedBytes: Int64,
                capacityBytes: Int64 = 0, freeBytes: Int64 = 0, installedArtworkIDs: [String] = [], generatedAt: Date = Date()) {
        self.manifestID = manifestID
        self.readyTrackIDs = readyTrackIDs
        self.installedBytes = installedBytes
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.installedArtworkIDs = installedArtworkIDs
        self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case manifestID, readyTrackIDs, installedBytes, capacityBytes, freeBytes, installedArtworkIDs, generatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifestID = try container.decode(String.self, forKey: .manifestID)
        readyTrackIDs = try container.decode([WatchTrackID].self, forKey: .readyTrackIDs)
        installedBytes = try container.decode(Int64.self, forKey: .installedBytes)
        capacityBytes = try container.decodeIfPresent(Int64.self, forKey: .capacityBytes) ?? 0
        freeBytes = try container.decodeIfPresent(Int64.self, forKey: .freeBytes) ?? 0
        installedArtworkIDs = try container.decodeIfPresent([String].self, forKey: .installedArtworkIDs) ?? []
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
    }
}

/// The coalesced application-context payload (§5.2: newest state only). Both sides publish one of
/// these; the fields each populates differ, which is why every member below is optional.
public struct WatchContextSnapshot: Codable, Equatable, Sendable {
    public var pairedLibraryID: WatchPairedLibraryID
    public var protocolVersion: Int
    public var phoneRevision: Int64
    public var updatedAt: Date
    public var playback: WatchPhonePlaybackSnapshot?
    public var downloads: WatchDownloadStatusSnapshot?
    public var manifest: WatchManifestPayload?

    public init(pairedLibraryID: WatchPairedLibraryID, protocolVersion: Int = WatchProtocolEnvelope.currentProtocolVersion,
                phoneRevision: Int64 = 0, updatedAt: Date = Date(),
                playback: WatchPhonePlaybackSnapshot? = nil,
                downloads: WatchDownloadStatusSnapshot? = nil,
                manifest: WatchManifestPayload? = nil) {
        self.pairedLibraryID = pairedLibraryID
        self.protocolVersion = protocolVersion
        self.phoneRevision = phoneRevision
        self.updatedAt = updatedAt
        self.playback = playback
        self.downloads = downloads
        self.manifest = manifest
    }
}
