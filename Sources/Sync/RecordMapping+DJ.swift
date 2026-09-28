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
    public static func record(from prep: DJTrackPrep, trackSyncID: String?,
                              trackKeys: [TrackIdentityKey], zoneID: CKRecordZone.ID) -> CKRecord {
        let syncID = prep.syncID ?? UUID().uuidString
        let record = CKRecord(recordType: RecordType.djTrackPrep.rawValue,
                              recordID: recordID(type: .djTrackPrep, syncID: syncID, zoneID: zoneID))
        record["syncID"] = syncID as CKRecordValue
        record["trackSyncID"] = trackSyncID as CKRecordValue?
        record["trackKeys"] = trackKeys.map(\.cloudValue) as CKRecordValue
        record["hotCues"] = prep.hotCuesJSON as CKRecordValue
        record["cuePointSeconds"] = prep.cuePointSeconds as CKRecordValue?
        record["loopInSeconds"] = prep.loopInSeconds as CKRecordValue?
        record["loopOutSeconds"] = prep.loopOutSeconds as CKRecordValue?
        record["hotCuesUpdatedAt"] = prep.hotCuesUpdatedAt as CKRecordValue?
        if let payload = prep.analysisPayload, payload.count <= 700_000 {
            record["analysisPayload"] = payload as CKRecordValue
            record["analysisAlgorithm"] = prep.analysisAlgorithm as CKRecordValue?
            record["analysisPayloadVersion"] = prep.analysisPayloadVersion as CKRecordValue?
            record["sourceSampleRate"] = prep.sourceSampleRate as CKRecordValue?
            record["sourceFrameCount"] = prep.sourceFrameCount as CKRecordValue?
            record["bpm"] = prep.bpm as CKRecordValue?
            record["camelotKey"] = prep.camelotKey as CKRecordValue?
        }
        // Keep the edit clock even when the optional analysis blob is too
        // large for a CKRecord. Grid overrides still need deterministic LWW
        // behavior in that case.
        record["analysisUpdatedAt"] = prep.analysisUpdatedAt as CKRecordValue?
        record["bpmOverride"] = prep.bpmOverride as CKRecordValue?
        record["firstBeatOverride"] = prep.firstBeatOverride as CKRecordValue?
        record["keyShiftSemitones"] = prep.keyShiftSemitones as CKRecordValue
        return record
    }

    public static func djTrackPrep(from record: CKRecord) -> DJTrackPrepEnvelope? {
        guard let syncID = record["syncID"] as? String,
              let hotCues = record["hotCues"] as? String else { return nil }
        let prep = DJTrackPrep(trackId: 0, hotCuesJSON: hotCues,
                               cuePointSeconds: record["cuePointSeconds"] as? Double,
                               loopInSeconds: record["loopInSeconds"] as? Double,
                               loopOutSeconds: record["loopOutSeconds"] as? Double,
                               hotCuesUpdatedAt: record["hotCuesUpdatedAt"] as? Date,
                               analysisPayload: record["analysisPayload"] as? Data,
                               analysisAlgorithm: record["analysisAlgorithm"] as? String,
                               analysisPayloadVersion: record["analysisPayloadVersion"] as? Int,
                               sourceSampleRate: record["sourceSampleRate"] as? Double,
                               sourceFrameCount: record["sourceFrameCount"] as? Int64,
                               bpm: record["bpm"] as? Double,
                               camelotKey: record["camelotKey"] as? String,
                               analysisUpdatedAt: record["analysisUpdatedAt"] as? Date,
                               syncID: syncID,
                               bpmOverride: record["bpmOverride"] as? Double,
                               firstBeatOverride: record["firstBeatOverride"] as? Double,
                               keyShiftSemitones: record["keyShiftSemitones"] as? Int ?? 0)
        return DJTrackPrepEnvelope(prep: prep, trackSyncID: record["trackSyncID"] as? String,
                                   trackKeys: TrackIdentity.parse(record["trackKeys"] as? [String] ?? []))
    }
}
#endif
