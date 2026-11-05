import Foundation

#if !os(watchOS)
import CloudKit

public struct DJTrackPrepEnvelope: Sendable {
    public var prep: DJTrackPrep
    public var trackSyncID: String?
    public var trackKeys: [TrackIdentityKey]

    public init(prep: DJTrackPrep, trackSyncID: String?, trackKeys: [TrackIdentityKey] = []) {
        self.prep = prep; self.trackSyncID = trackSyncID; self.trackKeys = trackKeys
    }
}

extension RecordMapping {
    /// Decode-only now: nothing in this app ever enqueues a `DJTrackPrep` record to push
    /// (`enqueueDJTrackPrep` was removed as dead code — see `CloudSyncEngine`), so there is no
    /// more encode side. This only decodes an already-pending legacy record from an old app
    /// version's sync history. Any other legacy keys on the record (`hotCues`, `loopInSeconds`,
    /// the analysis-payload blob, …) are simply never read — optional `as?` casts tolerate their
    /// absence just as readily as their presence.
    public static func djTrackPrep(from record: CKRecord) -> DJTrackPrepEnvelope? {
        guard let syncID = record["syncID"] as? String else { return nil }
        let prep = DJTrackPrep(trackId: 0,
                               bpm: record["bpm"] as? Double,
                               camelotKey: record["camelotKey"] as? String,
                               analysisUpdatedAt: record["analysisUpdatedAt"] as? Date,
                               syncID: syncID,
                               bpmOverride: record["bpmOverride"] as? Double)
        return DJTrackPrepEnvelope(prep: prep, trackSyncID: record["trackSyncID"] as? String,
                                   trackKeys: TrackIdentity.parse(record["trackKeys"] as? [String] ?? []))
    }
}
#endif
