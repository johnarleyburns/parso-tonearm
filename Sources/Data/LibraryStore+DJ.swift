import Foundation
import GRDB

extension LibraryStore {
    /// Returns the current, displayable musical values for the requested
    /// tracks. Discovery analysis is preferred because it is the shared
    /// library result; DJ prep supplies a user BPM override and remains a
    /// fallback for tracks prepared by the DJ surface before discovery has
    /// completed.
    public func djLoadTrackInfo(trackIds: [Int64]) throws -> [Int64: DJLoadTrackInfo] {
        let ids = Array(Set(trackIds.filter { $0 >= 0 }))
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            var result: [Int64: DJLoadTrackInfo] = [:]
            for id in ids {
                let asset = try Asset.filter(Column("trackId") == id).fetchOne(db)
                let analysis = try DiscoveryTrackAnalysis.fetchOne(db, key: id)
                let analysisIsCurrent: Bool = {
                    guard let asset, let analysis else { return false }
                    // Asset currently has no persisted content-revision field
                    // in TonearmCore. Its stable row identity is still the
                    // strongest local validity check available here; the
                    // discovery worker handles revision invalidation before
                    // writing a result.
                    return analysis.assetId == asset.id
                }()
                let prep = try DJTrackPrep.fetchOne(db, key: id)
                let bpm = prep?.bpmOverride
                    ?? (analysisIsCurrent ? analysis?.bpm : nil)
                    ?? prep?.bpm
                let key = (analysisIsCurrent ? analysis?.key : nil) ?? prep?.camelotKey
                result[id] = DJLoadTrackInfo(bpm: bpm, camelotKey: key)
            }
            return result
        }
    }

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

    public func djTrackPrepBySyncID(_ syncID: String) throws -> DJTrackPrep? {
        try dbQueue.read { db in try DJTrackPrep.filter(Column("syncID") == syncID).fetchOne(db) }
    }

    public func trackSyncID(trackId: Int64) throws -> String? {
        try dbQueue.read { db in try Track.fetchOne(db, key: trackId)?.syncID }
    }

    public func saveDJMarkings(_ markings: DJMarkings, trackId: Int64, at date: Date = Date()) throws {
        guard trackId >= 0 else { return }
        guard (markings.loopInSeconds == nil) == (markings.loopOutSeconds == nil),
              markings.loopInSeconds == nil || markings.loopOutSeconds! > markings.loopInSeconds! else { return }
        var stored: [String: DJStoredCue] = [:]
        for (slot, time) in markings.hotCues {
            guard (1...8).contains(slot) else { continue }
            stored[String(slot)] = DJStoredCue(t: time, c: markings.hotCueColors[slot] ?? (slot - 1) % 8,
                                              loopIn: nil, loopOut: nil)
        }
        for (slot, loop) in markings.hotLoops where (1...8).contains(slot) {
            stored[String(slot)] = DJStoredCue(t: loop.position, c: loop.color,
                                              loopIn: loop.loopIn, loopOut: loop.loopOut)
        }
        let json = String(data: try JSONEncoder().encode(stored), encoding: .utf8) ?? "{}"
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

    public func saveDJGrid(bpmOverride: Double?, firstBeatOverride: Double?, keyShiftSemitones: Int,
                           trackId: Int64, at date: Date = Date()) throws {
        guard trackId >= 0 else { return }
        try dbQueue.write { db in
            var row = try DJTrackPrep.fetchOne(db, key: trackId) ?? DJTrackPrep(trackId: trackId)
            row.bpmOverride = bpmOverride
            row.firstBeatOverride = firstBeatOverride
            row.keyShiftSemitones = keyShiftSemitones
            row.analysisUpdatedAt = date
            try row.save(db)
        }
    }

    public func clearDJAnalysis(trackId: Int64) throws { try dbQueue.write { db in try db.execute(sql: "UPDATE dj_track_prep SET analysisPayload = NULL, analysisAlgorithm = NULL, analysisPayloadVersion = NULL, sourceSampleRate = NULL, sourceFrameCount = NULL, bpm = NULL, camelotKey = NULL, analysisUpdatedAt = NULL WHERE trackId = ?", arguments: [trackId]) } }
    public func clearAllDJAnalysis() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE dj_track_prep SET analysisPayload = NULL, analysisAlgorithm = NULL, analysisPayloadVersion = NULL, sourceSampleRate = NULL, sourceFrameCount = NULL, bpm = NULL, camelotKey = NULL, analysisUpdatedAt = NULL")
        }
    }
    public func clearDJHotCues(trackId: Int64) throws { try dbQueue.write { db in try db.execute(sql: "UPDATE dj_track_prep SET hotCuesJSON = '{}', hotCuesUpdatedAt = ? WHERE trackId = ?", arguments: [Date(), trackId]) } }
    public func clearDJLoop(trackId: Int64) throws { try dbQueue.write { db in try db.execute(sql: "UPDATE dj_track_prep SET loopInSeconds = NULL, loopOutSeconds = NULL, hotCuesUpdatedAt = ? WHERE trackId = ?", arguments: [Date(), trackId]) } }
    public func ensureDJTrackPrepSyncID(trackId: Int64) throws -> String? {
        try dbQueue.write { db in
            guard var row = try DJTrackPrep.fetchOne(db, key: trackId) else { return nil }
            if row.syncID == nil { row.syncID = UUID().uuidString; try row.update(db) }
            return row.syncID
        }
    }

    public func djPrepStorageStats() throws -> (tracks: Int, bytes: Int64) {
        try dbQueue.read { db in
            let tracks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dj_track_prep") ?? 0
            let bytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(analysisPayload)), 0) FROM dj_track_prep") ?? 0
            return (tracks, bytes)
        }
    }

#if !os(watchOS)
    public func applyIncomingDJTrackPrep(_ envelope: DJTrackPrepEnvelope) throws -> Int {
        let ids = try localTrackIds(matching: envelope.trackKeys, trackSyncID: envelope.trackSyncID)
        guard !ids.isEmpty else { return 0 }
        var applied = 0
        try dbQueue.write { db in
            for id in ids {
                var local = try DJTrackPrep.fetchOne(db, key: id) ?? DJTrackPrep(trackId: id)
                let incoming = envelope.prep
                if let remoteDate = incoming.hotCuesUpdatedAt,
                   local.hotCuesUpdatedAt == nil || remoteDate > local.hotCuesUpdatedAt! {
                    local.hotCuesJSON = incoming.hotCuesJSON
                    local.cuePointSeconds = incoming.cuePointSeconds
                    local.loopInSeconds = incoming.loopInSeconds
                    local.loopOutSeconds = incoming.loopOutSeconds
                    local.hotCuesUpdatedAt = remoteDate
                }
                let incomingAnalysisIsNewer: Bool = {
                    guard incoming.analysisPayload != nil || incoming.analysisUpdatedAt != nil else { return false }
                    guard let localDate = local.analysisUpdatedAt else { return true }
                    if let incomingDate = incoming.analysisUpdatedAt { return incomingDate > localDate }
                    let incomingVersion = incoming.analysisPayloadVersion ?? 0
                    return incomingVersion > (local.analysisPayloadVersion ?? 0)
                }()
                if incoming.analysisPayload != nil, incomingAnalysisIsNewer {
                    local.analysisPayload = incoming.analysisPayload
                    local.analysisAlgorithm = incoming.analysisAlgorithm
                    local.analysisPayloadVersion = incoming.analysisPayloadVersion
                    local.sourceSampleRate = incoming.sourceSampleRate
                    local.sourceFrameCount = incoming.sourceFrameCount
                    local.bpm = incoming.bpm
                    local.camelotKey = incoming.camelotKey
                    local.analysisUpdatedAt = incoming.analysisUpdatedAt
                }
                if incomingAnalysisIsNewer {
                    local.bpmOverride = incoming.bpmOverride
                    local.firstBeatOverride = incoming.firstBeatOverride
                    local.keyShiftSemitones = incoming.keyShiftSemitones
                }
                local.syncID = local.syncID ?? incoming.syncID
                try local.save(db)
                if var track = try Track.fetchOne(db, key: id), track.syncID == nil {
                    track.syncID = envelope.prep.syncID
                    try track.update(db)
                }
                applied += 1
            }
        }
        return applied
    }
#endif
}
