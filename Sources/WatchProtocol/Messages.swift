import Foundation

/// §5.3 — the complete set of request kinds. Raw values are wire format.
public enum WatchMessageKind: String, Codable, Sendable, CaseIterable {
    case hello, helloReply
    case searchRequest, searchResponse
    case browseRequest, browseResponse
    case collectionRequest, collectionResponse
    case playCommand, commandReply
    case phonePlaybackSnapshot
    case setDownloadRoots
    case downloadStatusSnapshot
    case watchManifest
    case requestReconciliation
    case removeAssets
    case error

    /// Which WCSession channel §5.2 assigns this kind. The router uses it to refuse, for example, a
    /// `setDownloadRoots` that arrived over the immediate channel and would therefore be lost on a
    /// locked phone.
    public var channel: WatchTransportChannel {
        switch self {
        case .hello, .helloReply, .searchRequest, .searchResponse, .browseRequest, .browseResponse,
             .collectionRequest, .collectionResponse, .playCommand, .commandReply, .error:
            .immediate
        case .phonePlaybackSnapshot, .downloadStatusSnapshot:
            .applicationContext
        case .setDownloadRoots, .watchManifest, .requestReconciliation, .removeAssets:
            .userInfo
        }
    }

    /// A kind that carries a monotonic revision and must therefore pass the revision gate before it
    /// is applied (§5.4).
    public var isRevisioned: Bool {
        switch self {
        case .setDownloadRoots, .removeAssets, .phonePlaybackSnapshot, .downloadStatusSnapshot: true
        default: false
        }
    }
}

// MARK: - Negotiation

/// A named capability, so a newer peer can offer something an older one simply does not list rather
/// than failing the whole session. §1.5: reachability is a capability, not the database mode.
public enum WatchCapability: String, Codable, Sendable, CaseIterable {
    case connectedSearch
    case connectedBrowse
    case collectionDetail
    case phonePlaybackControl
    case downloadRoots
    case manifestAcknowledgement
    case reconciliation
}

public struct WatchHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var pairedLibraryID: WatchPairedLibraryID
    public var capabilities: [WatchCapability]
    /// Last phone revision the watch has applied, so the phone knows whether to resend.
    public var lastAppliedPhoneRevision: Int64

    public init(protocolVersion: Int = WatchProtocolEnvelope.currentProtocolVersion,
                pairedLibraryID: WatchPairedLibraryID = .unknown,
                capabilities: [WatchCapability] = WatchCapability.allCases,
                lastAppliedPhoneRevision: Int64 = 0) {
        self.protocolVersion = protocolVersion
        self.pairedLibraryID = pairedLibraryID
        self.capabilities = capabilities
        self.lastAppliedPhoneRevision = lastAppliedPhoneRevision
    }
}

public struct WatchHelloReply: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var pairedLibraryID: WatchPairedLibraryID
    public var capabilities: [WatchCapability]
    public var phoneRevision: Int64

    public init(protocolVersion: Int = WatchProtocolEnvelope.currentProtocolVersion,
                pairedLibraryID: WatchPairedLibraryID, capabilities: [WatchCapability] = WatchCapability.allCases,
                phoneRevision: Int64 = 0) {
        self.protocolVersion = protocolVersion
        self.pairedLibraryID = pairedLibraryID
        self.capabilities = capabilities
        self.phoneRevision = phoneRevision
    }
}

/// The negotiated result of one `hello`/`helloReply` exchange.
public struct WatchNegotiatedSession: Equatable, Sendable {
    public var protocolVersion: Int
    public var pairedLibraryID: WatchPairedLibraryID
    public var capabilities: Set<WatchCapability>
    public var phoneRevision: Int64

    public init(protocolVersion: Int, pairedLibraryID: WatchPairedLibraryID,
                capabilities: Set<WatchCapability>, phoneRevision: Int64) {
        self.protocolVersion = protocolVersion
        self.pairedLibraryID = pairedLibraryID
        self.capabilities = capabilities
        self.phoneRevision = phoneRevision
    }

    public func supports(_ capability: WatchCapability) -> Bool { capabilities.contains(capability) }
}

public enum WatchCapabilityNegotiation {
    /// Versions must match exactly: §5.1 gives no compatibility window, and pretending a v2 peer is
    /// a v1 peer is how a silently-dropped field becomes a corrupted library.
    public static func negotiate(local: WatchHello, remote: WatchHelloReply) -> Result<WatchNegotiatedSession, WatchProtocolFault> {
        guard local.protocolVersion == remote.protocolVersion else {
            return .failure(WatchProtocolFault(code: .protocolUpgradeRequired))
        }
        return .success(WatchNegotiatedSession(
            protocolVersion: remote.protocolVersion,
            pairedLibraryID: remote.pairedLibraryID,
            capabilities: Set(local.capabilities).intersection(remote.capabilities),
            phoneRevision: remote.phoneRevision))
    }
}

// MARK: - Search and browse

public enum WatchSearchScope: String, Codable, Sendable, CaseIterable {
    case all, tracks, albums, playlists, artists
}

public struct WatchSearchRequest: Codable, Equatable, Sendable {
    public var query: String
    public var scope: WatchSearchScope
    public var pageToken: String?
    /// §6.1: generation IDs cause late replies to be dropped.
    public var generation: Int
    public var limit: Int

    /// §6.1 caps a page at 30 mixed results.
    public static let maximumPageSize = 30
    /// §6.1 debounces text input by 250 ms after two non-whitespace characters.
    public static let debounceInterval: TimeInterval = 0.25
    public static let minimumQueryLength = 2

    public init(query: String, scope: WatchSearchScope = .all, pageToken: String? = nil,
                generation: Int, limit: Int = WatchSearchRequest.maximumPageSize) {
        self.query = query
        self.scope = scope
        self.pageToken = pageToken
        self.generation = generation
        self.limit = min(max(1, limit), Self.maximumPageSize)
    }

    /// Whether this query is long enough to submit without an explicit Search tap.
    public static func isSubmittableWhileTyping(_ query: String) -> Bool {
        query.filter { !$0.isWhitespace }.count >= minimumQueryLength
    }
}

public enum WatchResultKind: String, Codable, Sendable, CaseIterable {
    case track, album, playlist, artist
}

/// One typed row. §6.1 requires typed track/playlist/album rows rather than a bag of strings, and
/// this is deliberately narrower than `WatchTrackSummary`: a search row is a label and a target.
public struct WatchResultRow: Codable, Equatable, Sendable, Identifiable {
    public var kind: WatchResultKind
    public var id: String
    public var title: String
    public var subtitle: String?
    public var artworkID: String?
    public var trackCount: Int?
    public var durationSeconds: Double?
    public var isDownloadedOnWatch: Bool

    public init(kind: WatchResultKind, id: String, title: String, subtitle: String? = nil,
                artworkID: String? = nil, trackCount: Int? = nil, durationSeconds: Double? = nil,
                isDownloadedOnWatch: Bool = false) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkID = artworkID
        self.trackCount = trackCount
        self.durationSeconds = durationSeconds
        self.isDownloadedOnWatch = isDownloadedOnWatch
    }

    public var collectionRef: WatchCollectionRef? {
        switch kind {
        case .playlist: WatchCollectionRef(kind: .playlist, id: id)
        case .album: WatchCollectionRef(kind: .album, id: id)
        case .track, .artist: nil
        }
    }
}

public struct WatchSearchResponse: Codable, Equatable, Sendable {
    public var generation: Int
    public var query: String
    public var rows: [WatchResultRow]
    public var nextPageToken: String?

    public init(generation: Int, query: String, rows: [WatchResultRow], nextPageToken: String? = nil) {
        self.generation = generation
        self.query = query
        self.rows = rows
        self.nextPageToken = nextPageToken
    }
}

public enum WatchBrowseCategory: String, Codable, Sendable, CaseIterable {
    case playlists, albums, songs, recent
}

public struct WatchBrowseRequest: Codable, Equatable, Sendable {
    public var category: WatchBrowseCategory
    public var pageToken: String?
    public var generation: Int
    public var limit: Int

    public static let maximumPageSize = 30

    public init(category: WatchBrowseCategory, pageToken: String? = nil, generation: Int,
                limit: Int = WatchBrowseRequest.maximumPageSize) {
        self.category = category
        self.pageToken = pageToken
        self.generation = generation
        self.limit = min(max(1, limit), Self.maximumPageSize)
    }
}

public struct WatchBrowseResponse: Codable, Equatable, Sendable {
    public var category: WatchBrowseCategory
    public var generation: Int
    public var rows: [WatchResultRow]
    public var nextPageToken: String?

    public init(category: WatchBrowseCategory, generation: Int, rows: [WatchResultRow],
                nextPageToken: String? = nil) {
        self.category = category
        self.generation = generation
        self.rows = rows
        self.nextPageToken = nextPageToken
    }
}

public struct WatchCollectionRequest: Codable, Equatable, Sendable {
    public var collection: WatchCollectionRef
    public var pageToken: String?
    public var limit: Int

    public static let maximumPageSize = 50

    public init(collection: WatchCollectionRef, pageToken: String? = nil,
                limit: Int = WatchCollectionRequest.maximumPageSize) {
        self.collection = collection
        self.pageToken = pageToken
        self.limit = min(max(1, limit), Self.maximumPageSize)
    }
}

public struct WatchCollectionResponse: Codable, Equatable, Sendable {
    public var collection: WatchCollectionRef
    public var title: String
    public var tracks: [WatchTrackSummary]
    public var totalCount: Int
    public var nextPageToken: String?

    public init(collection: WatchCollectionRef, title: String, tracks: [WatchTrackSummary],
                totalCount: Int, nextPageToken: String? = nil) {
        self.collection = collection
        self.title = title
        self.tracks = tracks
        self.totalCount = totalCount
        self.nextPageToken = nextPageToken
    }

    /// D-11: an empty playlist has to be visibly nonplayable, so the emptiness travels as a fact
    /// rather than being inferred from a truncated page.
    public var isPlayable: Bool { totalCount > 0 }
}

// MARK: - Playback commands

public enum WatchTransportAction: String, Codable, Sendable, CaseIterable {
    case play, pause, togglePlayPause, next, previous
    case jumpToIndex, seek
    case setShuffle, setRepeat
    case playCollection, playTrack
}

/// §5.3 `playCommand`. §7.1 makes targets explicit: this type only ever addresses the *phone*
/// player. Watch-local transport never travels over the link.
public struct WatchPlayCommand: Codable, Equatable, Sendable {
    public var action: WatchTransportAction
    public var collection: WatchCollectionRef?
    public var trackID: WatchTrackID?
    public var startIndex: Int?
    public var seekSeconds: Double?
    public var shuffleEnabled: Bool?
    public var repeatMode: WatchRepeatMode?

    public init(action: WatchTransportAction, collection: WatchCollectionRef? = nil,
                trackID: WatchTrackID? = nil, startIndex: Int? = nil, seekSeconds: Double? = nil,
                shuffleEnabled: Bool? = nil, repeatMode: WatchRepeatMode? = nil) {
        self.action = action
        self.collection = collection
        self.trackID = trackID
        self.startIndex = startIndex
        self.seekSeconds = seekSeconds
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
    }

    /// D-06: a playlist plays in stored order from index zero unless a row was tapped.
    public static func playCollection(_ collection: WatchCollectionRef, startIndex: Int = 0) -> Self {
        .init(action: .playCollection, collection: collection, startIndex: startIndex)
    }

    public static func playTrack(_ trackID: WatchTrackID, in collection: WatchCollectionRef? = nil) -> Self {
        .init(action: .playTrack, collection: collection, trackID: trackID)
    }
}

/// D-10: a command never silently no-ops. Either it was accepted, or it names the reason.
public struct WatchCommandReply: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var fault: WatchProtocolFault?
    public var snapshot: WatchPhonePlaybackSnapshot?

    public init(accepted: Bool, fault: WatchProtocolFault? = nil,
                snapshot: WatchPhonePlaybackSnapshot? = nil) {
        self.accepted = accepted
        self.fault = fault
        self.snapshot = snapshot
    }

    public static func accepted(_ snapshot: WatchPhonePlaybackSnapshot? = nil) -> Self {
        .init(accepted: true, snapshot: snapshot)
    }

    public static func rejected(_ code: WatchProtocolErrorCode) -> Self {
        .init(accepted: false, fault: WatchProtocolFault(code: code))
    }
}

// MARK: - Durable events

public enum WatchRootKind: String, Codable, Sendable, CaseIterable {
    case track, playlist, albumBatch
}

public struct WatchDownloadRootDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var rootID: WatchDownloadRootID
    public var kind: WatchRootKind
    /// The playlist/album/track this root was created from. An opaque key, never a URL.
    public var sourceID: String
    public var title: String
    public var trackIDs: [WatchTrackID]

    public var id: WatchDownloadRootID { rootID }

    public init(rootID: WatchDownloadRootID, kind: WatchRootKind, sourceID: String,
                title: String = "", trackIDs: [WatchTrackID]) {
        self.rootID = rootID
        self.kind = kind
        self.sourceID = sourceID
        self.title = title
        self.trackIDs = trackIDs
    }
}

/// §5.3 `setDownloadRoots` — a *complete* desired-root revision, not a delta. A delta protocol
/// cannot recover from a dropped message; a full set converges after any number of them.
public struct WatchSetDownloadRoots: Codable, Equatable, Sendable {
    public var revision: Int64
    public var roots: [WatchDownloadRootDescriptor]

    public init(revision: Int64, roots: [WatchDownloadRootDescriptor]) {
        self.revision = revision
        self.roots = roots
    }

    /// E-04/E-05: one track required by two roots is still one desired track, and dropping one root
    /// must not drop it.
    public var desiredTrackIDs: Set<WatchTrackID> { Set(roots.flatMap(\.trackIDs)) }
}

public enum WatchRemovalReason: String, Codable, Sendable, CaseIterable {
    case userRemoved, rootRemoved, sourceDeleted, storageReclaimed
}

public struct WatchRemoveAssets: Codable, Equatable, Sendable {
    public var revision: Int64
    public var trackIDs: [WatchTrackID]
    public var reason: WatchRemovalReason

    public init(revision: Int64, trackIDs: [WatchTrackID], reason: WatchRemovalReason = .userRemoved) {
        self.revision = revision
        self.trackIDs = trackIDs
        self.reason = reason
    }
}

public enum WatchReconciliationScope: String, Codable, Sendable, CaseIterable {
    case catalog, downloadRoots, manifest, playbackState, all
}

public struct WatchReconciliationRequest: Codable, Equatable, Sendable {
    public var scope: WatchReconciliationScope
    /// Why the request went out — H-07 shows a Reconcile action, and a store rebuild asks on its
    /// own. A code, never a sentence.
    public var trigger: WatchProtocolErrorCode?

    public init(scope: WatchReconciliationScope = .all, trigger: WatchProtocolErrorCode? = nil) {
        self.scope = scope
        self.trigger = trigger
    }
}
