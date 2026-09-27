import Foundation
import GRDB

extension LibraryStore {
    public func djTrackPrep(trackId: Int64) throws -> DJTrackPrep? {
        guard trackId >= 0 else { return nil }
        if let existing = try dbQueue.read({ db in try DJTrackPrep.fetchOne(db, key: trackId) }) { return existing }
        guard let legacy = UserDefaults.standard.dictionary(forKey: "dj.hotCues.v1.\(trackId)") as? [String: Double] else { return nil }
        let json = String(data: try JSONEncoder().encode(legacy), encoding: .utf8) ?? "{}"
        let imported = DJTrackPrep(trackId: trackId, hotCuesJSON: json, hotCuesUpdatedAt: Date())
        try dbQueue.write { db in var value = imported; try value.insert(db) }
        UserDefaults.standard.removeObject(forKey: "dj.hotCues.v1.\(trackId)")
        return imported
    }

    public func saveDJMarkings(_ markings: DJMarkings, trackId: Int64, at date: Date = Date()) throws {
        guard trackId >= 0 else { return }
        guard (markings.loopInSeconds == nil) == (markings.loopOutSeconds == nil),
              markings.loopInSeconds == nil || markings.loopOutSeconds! > markings.loopInSeconds! else { return }
        let json = String(data: try JSONEncoder().encode(markings.hotCues.reduce(into: [:]) { $0[String($1.key)] = $1.value }), encoding: .utf8) ?? "{}"
        try dbQueue.write { db in
            var row = try DJTrackPrep.fetchOne(db, key: trackId) ?? DJTrackPrep(trackId: trackId)
            row.hotCuesJSON = json; row.cuePointSeconds = markings.cuePointSeconds
            row.loopInSeconds = markings.loopInSeconds; row.loopOutSeconds = markings.loopOutSeconds
            row.hotCuesUpdatedAt = date
            try row.save(db)
        }
    }

    public func saveDJAnalysis(_ payload: Data, meta: (algorithm: String, version: Int, sampleRate: Double, frameCount: Int64, bpm: Double?, key: String?), trackId: Int64, at date: Date = Date()) throws {
        guard trackId >= 0 else { return }
        try dbQueue.write { db in
            var row = try DJTrackPrep.fetchOne(db, key: trackId) ?? DJTrackPrep(trackId: trackId)
            row.analysisPayload = payload; row.analysisAlgorithm = meta.algorithm
            row.analysisPayloadVersion = meta.version; row.sourceSampleRate = meta.sampleRate
            row.sourceFrameCount = meta.frameCount; row.bpm = meta.bpm; row.camelotKey = meta.key
            row.analysisUpdatedAt = date; try row.save(db)
        }
    }

    public func clearDJAnalysis(trackId: Int64) throws { try dbQueue.write { db in try db.execute(sql: "UPDATE dj_track_prep SET analysisPayload = NULL, analysisAlgorithm = NULL, analysisPayloadVersion = NULL, sourceSampleRate = NULL, sourceFrameCount = NULL, bpm = NULL, camelotKey = NULL, analysisUpdatedAt = NULL WHERE trackId = ?", arguments: [trackId]) } }
    public func clearDJHotCues(trackId: Int64) throws { try dbQueue.write { db in try db.execute(sql: "UPDATE dj_track_prep SET hotCuesJSON = '{}', hotCuesUpdatedAt = ? WHERE trackId = ?", arguments: [Date(), trackId]) } }
    public func clearDJLoop(trackId: Int64) throws { try dbQueue.write { db in try db.execute(sql: "UPDATE dj_track_prep SET loopInSeconds = NULL, loopOutSeconds = NULL, hotCuesUpdatedAt = ? WHERE trackId = ?", arguments: [Date(), trackId]) } }
    public func ensureDJTrackPrepSyncID(trackId: Int64) throws -> String? {
        try dbQueue.write { db in
            guard var row = try DJTrackPrep.fetchOne(db, key: trackId) else { return nil }
            if row.syncID == nil { row.syncID = UUID().uuidString; try row.update(db) }
            return row.syncID
        }
    }
}
