import Foundation
import GRDB
import TonearmWatchProtocol

/// The phone-side download subsystem (watch rearchitecture §8.1–§8.2).
///
/// §1.6: the iPhone owns *desired download roots*; the watch owns *installed asset truth*. These
/// are the phone's half — a persisted set of roots, the jobs that satisfy them, and the watch's
/// last-reported manifest, reconciled by `PhoneWatchDownloadPlanner` into a deterministic plan.
///
/// Everything here is a value type or a GRDB record so the whole pipeline runs under `swift test`;
/// the only Xcode-only piece is the `WCSession.transferFile` adapter (`Sources/App/Watch`).

// MARK: - Job lifecycle

/// The phone's view of one track transfer. The watch has its own `installing`/`ready` states for
/// what happens after delivery; the phone stops at `sent`.
public enum PhoneWatchJobState: String, Codable, Sendable, CaseIterable {
    case queued        // persisted, not yet dispatched
    case resolving     // fetching the source audio into the phone cache
    case waitingForWiFi // resolved, but network policy forbids the transfer right now
    case transferring  // handed to the transfer seam
    case sent          // the framework accepted the file; the watch installs from here
    case failed
    case cancelled
}

/// Why a job failed, which decides whether the scheduler retries it (§8.2). Transient failures
/// back off and retry; the rest require user action and never spin.
public enum PhoneWatchFailureClass: String, Codable, Sendable, CaseIterable {
    case transient        // network blip, timeout — retry with backoff
    case needsAuth        // source needs re-authentication — user action
    case sourceUnavailable // the remote source is gone — user action
    case fileUnsupported  // codec/container the watch can't play — permanent skip

    public var isRetryable: Bool { self == .transient }
}

// MARK: - Roots

/// A desired-download root. Playlist roots stay live (re-expanded on every plan); track and
/// album-batch roots are frozen snapshots of the track set at creation time (§4 `WatchDownloadRootModel`).
public struct PhoneWatchDownloadRoot: Equatable, Sendable, Codable {
    public var rootID: String
    public var kind: WatchRootKind
    /// The playlist/album/track key this root was created from. Opaque, never a URL.
    public var sourceID: String
    public var title: String
    /// Watch track IDs (the §4 stable strings), in root order.
    public var desiredTrackIDs: [String]
    public var phoneRevision: Int64
    public var createdAt: Date

    public init(rootID: String, kind: WatchRootKind, sourceID: String, title: String = "",
                desiredTrackIDs: [String], phoneRevision: Int64, createdAt: Date = Date()) {
        self.rootID = rootID
        self.kind = kind
        self.sourceID = sourceID
        self.title = title
        self.desiredTrackIDs = desiredTrackIDs
        self.phoneRevision = phoneRevision
        self.createdAt = createdAt
    }

    public var descriptor: WatchDownloadRootDescriptor {
        WatchDownloadRootDescriptor(
            rootID: WatchDownloadRootID(rootID), kind: kind, sourceID: sourceID,
            title: title, trackIDs: desiredTrackIDs.map(WatchTrackID.init))
    }
}

public struct PhoneWatchDownloadJob: Equatable, Sendable, Codable {
    public var requestID: String
    public var trackID: String
    public var rootIDs: [String]
    public var priority: PhoneWatchDownloadPriority
    public var state: PhoneWatchJobState
    public var failureClass: PhoneWatchFailureClass?
    public var attempt: Int
    public var nextAttemptAt: Date?
    public var expectedBytes: Int64?
    public var expectedSHA256: String?
    public var errorCode: String?
    public var message: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(requestID: String = UUID().uuidString, trackID: String, rootIDs: [String],
                priority: PhoneWatchDownloadPriority = .trackOrAlbumBatch,
                state: PhoneWatchJobState = .queued, failureClass: PhoneWatchFailureClass? = nil,
                attempt: Int = 0, nextAttemptAt: Date? = nil, expectedBytes: Int64? = nil,
                expectedSHA256: String? = nil, errorCode: String? = nil, message: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.requestID = requestID
        self.trackID = trackID
        self.rootIDs = rootIDs
        self.priority = priority
        self.state = state
        self.failureClass = failureClass
        self.attempt = attempt
        self.nextAttemptAt = nextAttemptAt
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256
        self.errorCode = errorCode
        self.message = message
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isActive: Bool {
        switch state {
        case .queued, .resolving, .waitingForWiFi, .transferring: return true
        case .sent, .failed, .cancelled: return false
        }
    }

    public var isRetryable: Bool {
        state == .failed && (failureClass?.isRetryable ?? false)
    }
}

// MARK: - Watch-reported manifest

public struct PhoneWatchManifestEntry: Equatable, Sendable, Codable {
    public var trackID: String
    public var bytes: Int64
    public var manifestID: String
    public var reportedAt: Date

    public init(trackID: String, bytes: Int64, manifestID: String, reportedAt: Date = Date()) {
        self.trackID = trackID
        self.bytes = bytes
        self.manifestID = manifestID
        self.reportedAt = reportedAt
    }
}

// MARK: - GRDB records

struct WatchDownloadRootRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "watchDownloadRoot"
    var rootID: String
    var kind: String
    var sourceID: String
    var title: String
    var desiredTrackIDs: [String]
    var phoneRevision: Int64
    var createdAt: Date

    init(_ root: PhoneWatchDownloadRoot) {
        rootID = root.rootID
        kind = root.kind.rawValue
        sourceID = root.sourceID
        title = root.title
        desiredTrackIDs = root.desiredTrackIDs
        phoneRevision = root.phoneRevision
        createdAt = root.createdAt
    }

    var value: PhoneWatchDownloadRoot {
        PhoneWatchDownloadRoot(
            rootID: rootID, kind: WatchRootKind(rawValue: kind) ?? .track, sourceID: sourceID,
            title: title, desiredTrackIDs: desiredTrackIDs, phoneRevision: phoneRevision,
            createdAt: createdAt)
    }
}

struct WatchDownloadJobRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "watchDownloadJob"
    var requestID: String
    var trackID: String
    var rootIDs: [String]
    var priority: Int
    var state: String
    var failureClass: String?
    var attempt: Int
    var nextAttemptAt: Date?
    var expectedBytes: Int64?
    var expectedSHA256: String?
    var errorCode: String?
    var message: String?
    var createdAt: Date
    var updatedAt: Date

    init(_ job: PhoneWatchDownloadJob) {
        requestID = job.requestID
        trackID = job.trackID
        rootIDs = job.rootIDs
        priority = job.priority.rawValue
        state = job.state.rawValue
        failureClass = job.failureClass?.rawValue
        attempt = job.attempt
        nextAttemptAt = job.nextAttemptAt
        expectedBytes = job.expectedBytes
        expectedSHA256 = job.expectedSHA256
        errorCode = job.errorCode
        message = job.message
        createdAt = job.createdAt
        updatedAt = job.updatedAt
    }

    var value: PhoneWatchDownloadJob {
        PhoneWatchDownloadJob(
            requestID: requestID, trackID: trackID, rootIDs: rootIDs,
            priority: PhoneWatchDownloadPriority(rawValue: priority) ?? .trackOrAlbumBatch,
            state: PhoneWatchJobState(rawValue: state) ?? .failed,
            failureClass: failureClass.flatMap(PhoneWatchFailureClass.init(rawValue:)),
            attempt: attempt, nextAttemptAt: nextAttemptAt, expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256, errorCode: errorCode, message: message,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

struct WatchDownloadManifestEntryRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "watchDownloadManifestEntry"
    var trackID: String
    var bytes: Int64
    var manifestID: String
    var reportedAt: Date

    init(_ entry: PhoneWatchManifestEntry) {
        trackID = entry.trackID
        bytes = entry.bytes
        manifestID = entry.manifestID
        reportedAt = entry.reportedAt
    }

    var value: PhoneWatchManifestEntry {
        PhoneWatchManifestEntry(trackID: trackID, bytes: bytes, manifestID: manifestID,
                                reportedAt: reportedAt)
    }
}

struct WatchDownloadRevisionRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "watchDownloadRevision"
    var id: Int64
    var value: Int64
}
