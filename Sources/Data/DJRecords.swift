import Foundation
import GRDB

/// Persisted bpm/key for a track, plus a user override and the sync bookkeeping that lets a
/// remote update win or lose against a local one. The DJ console that once wrote hot cues, loops,
/// and a full analysis-payload blob here is gone — those 13 columns were dropped (v44); only
/// `djLoadTrackInfo` ever read `bpm`/`camelotKey`/`bpmOverride` from this table.
public struct DJTrackPrep: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dj_track_prep"
    public var trackId: Int64
    public var bpm: Double?
    public var camelotKey: String?
    public var analysisUpdatedAt: Date?
    public var syncID: String?
    public var bpmOverride: Double?

    public init(trackId: Int64, bpm: Double? = nil, camelotKey: String? = nil,
                analysisUpdatedAt: Date? = nil, syncID: String? = nil, bpmOverride: Double? = nil) {
        self.trackId = trackId
        self.bpm = bpm
        self.camelotKey = camelotKey
        self.analysisUpdatedAt = analysisUpdatedAt
        self.syncID = syncID
        self.bpmOverride = bpmOverride
    }
}
