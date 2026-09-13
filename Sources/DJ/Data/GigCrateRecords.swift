import Foundation
import GRDB

// MARK: - Records (§14.3)

/// A `gig_crate` row (§14.3, FR-PLIST-9): a playlist promoted to performance
/// readiness — audio cached, stage-3 stems queued, all under a storage budget.
public struct GigCrate: Codable, Identifiable, FetchableRecord,
                        MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var name: String
    public var playlistID: Int64?
    public var smartCrateID: Int64?
    /// This crate's own stem-budget ceiling (§14.3, §43.6).
    public var storageBudgetBytes: Int64
    /// Drives LRU eviction (FR-ANL-9) — set when the crate is performed.
    public var lastPerformedAt: Date?
    public var createdAt: Date

    public init(id: Int64? = nil,
                syncID: String,
                name: String,
                playlistID: Int64? = nil,
                smartCrateID: Int64? = nil,
                storageBudgetBytes: Int64,
                lastPerformedAt: Date? = nil,
                createdAt: Date) {
        self.id = id
        self.syncID = syncID
        self.name = name
        self.playlistID = playlistID
        self.smartCrateID = smartCrateID
        self.storageBudgetBytes = storageBudgetBytes
        self.lastPerformedAt = lastPerformedAt
        self.createdAt = createdAt
    }

    public static let databaseTableName = "gig_crate"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The per-track stem states (`gig_crate_track.stemsState`, §14.3).
public enum GigCrateStemsState: String, Sendable, Equatable {
    case pending
    case running
    case ready
    case failed
    /// The crate's stems were evicted by the storage budget (§43.6); the full
    /// mix still plays and the track is re-queued on the next prepare.
    case evicted
}

/// A `gig_crate_track` row (§14.3): one track of a prepared crate with its
/// FR-LIB-8 audio-cached flag and stage-3 stem roll-up.
public struct GigCrateTrack: Codable, Identifiable, FetchableRecord,
                             MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var gigCrateID: Int64
    public var trackID: Int64
    public var position: Int
    /// FR-LIB-8: the audio is fully local and reachable. Set at promotion and
    /// refreshed as remote caching progresses; a deck never waits on a network.
    public var audioCached: Bool
    /// `pending|running|ready|failed|evicted` (§14.3).
    public var stemsState: String
    public var stemsBytes: Int64

    public init(id: Int64? = nil,
                gigCrateID: Int64,
                trackID: Int64,
                position: Int,
                audioCached: Bool = false,
                stemsState: String = GigCrateStemsState.pending.rawValue,
                stemsBytes: Int64 = 0) {
        self.id = id
        self.gigCrateID = gigCrateID
        self.trackID = trackID
        self.position = position
        self.audioCached = audioCached
        self.stemsState = stemsState
        self.stemsBytes = stemsBytes
    }

    public static let databaseTableName = "gig_crate_track"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
