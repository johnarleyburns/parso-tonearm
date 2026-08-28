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
    public var isDownloadedOnWatch: Bool

    public var id: WatchTrackID { trackID }

    public init(trackID: WatchTrackID, title: String, artist: String = "", albumTitle: String = "",
                durationSeconds: Double? = nil, artworkID: String? = nil,
                isDownloadedOnWatch: Bool = false) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.durationSeconds = durationSeconds
        self.artworkID = artworkID
        self.isDownloadedOnWatch = isDownloadedOnWatch
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

    public static let queueWindowLimit = 20

    public init(revision: Int64, source: WatchPlaybackSourceKind = .none, isPlaying: Bool = false,
                rate: Double = 0, currentItem: WatchTrackSummary? = nil,
                collection: WatchCollectionRef? = nil, collectionTitle: String? = nil,
                queueWindow: [WatchTrackSummary] = [], queueWindowStartIndex: Int = 0,
                queueIndex: Int = 0, queueCount: Int = 0, elapsedSeconds: Double = 0,
                elapsedAnchorDate: Date = Date(), shuffleEnabled: Bool = false,
                repeatMode: WatchRepeatMode = .off) {
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

    public init(revision: Int64, queuedCount: Int = 0, activeCount: Int = 0,
                waitingForWiFiCount: Int = 0, failedCount: Int = 0, readyCount: Int = 0,
                activeTransfers: [WatchTransferProgress] = []) {
        self.revision = revision
        self.queuedCount = queuedCount
        self.activeCount = activeCount
        self.waitingForWiFiCount = waitingForWiFiCount
        self.failedCount = failedCount
        self.readyCount = readyCount
        self.activeTransfers = activeTransfers
    }

    private enum CodingKeys: String, CodingKey {
        case revision, queuedCount, activeCount, waitingForWiFiCount, failedCount, readyCount, activeTransfers
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
    }

    public var isIdle: Bool { queuedCount == 0 && activeCount == 0 && waitingForWiFiCount == 0 }

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
    public var generatedAt: Date

    public init(manifestID: String, readyTrackIDs: [WatchTrackID], installedBytes: Int64,
                capacityBytes: Int64 = 0, freeBytes: Int64 = 0, generatedAt: Date = Date()) {
        self.manifestID = manifestID
        self.readyTrackIDs = readyTrackIDs
        self.installedBytes = installedBytes
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.generatedAt = generatedAt
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
