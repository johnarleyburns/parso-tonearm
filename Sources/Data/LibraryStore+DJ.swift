import Foundation
import GRDB

extension LibraryStore {
    /// Reads the authoritative discovery embedding in planner-friendly form.
    /// Quantization is intentionally decoded here so the UI never manufactures
    /// a similarity score from a track id or a random seed.
    public func discoveryEmbeddingVector(trackId: Int64) throws -> [Float]? {
        guard trackId >= 0,
              let row = try dbQueue.read({ db in try DiscoveryEmbedding.fetchOne(db, key: trackId) }),
              row.dimensions > 0,
              row.quantizedVector.count == row.dimensions,
              row.scale.isFinite else { return nil }
        return row.quantizedVector.map { Float(Int8(bitPattern: $0)) * Float(row.scale) }
    }

    /// Batch form of `discoveryEmbeddingVector(trackId:)`: one read for a whole Build a Mix source
    /// (a 1,000-track library made the per-track reads the slowest part of Generate).
    public func discoveryEmbeddingVectors(trackIds: [Int64]) throws -> [Int64: [Float]] {
        let ids = Array(Set(trackIds.filter { $0 >= 0 }))
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            var result: [Int64: [Float]] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                for row in try DiscoveryEmbedding.filter(chunk.contains(Column("trackId"))).fetchAll(db) {
                    guard row.dimensions > 0, row.quantizedVector.count == row.dimensions,
                          row.scale.isFinite else { continue }
                    result[row.trackId] = row.quantizedVector.map { Float(Int8(bitPattern: $0)) * Float(row.scale) }
                }
            }
            return result
        }
    }

    /// Batch energy values from the local discovery analysis, keyed by track.
    public func discoveryEnergies(trackIds: [Int64]) throws -> [Int64: Double] {
        let ids = Array(Set(trackIds.filter { $0 >= 0 }))
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            var result: [Int64: Double] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                for row in try DiscoveryTrackAnalysis.filter(chunk.contains(Column("trackId"))).fetchAll(db) {
                    if let energy = row.energy { result[row.trackId] = energy }
                }
            }
            return result
        }
    }

    /// Genres that have mixable tracks (a tempo and a Camelot key, by the same rules as
    /// `djLoadTrackInfo`), with their counts, most first. One aggregate query: the Mix builder's
    /// genre list needs no per-track rows (field report: the list took 5–20 s while every track's
    /// metadata and embedding loaded).
    public func mixableGenreCounts() throws -> [(name: String, count: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT genre, COUNT(*) AS n FROM (
                    SELECT TRIM(t.genre) AS genre,
                           COALESCE(prep.bpmOverride,
                                    CASE WHEN analysis.assetId = firstAsset.id THEN analysis.bpm END,
                                    prep.bpm) AS bpm,
                           UPPER(TRIM(COALESCE(
                                    CASE WHEN analysis.assetId = firstAsset.id THEN analysis.key END,
                                    prep.camelotKey))) AS camelot
                    FROM track t
                    LEFT JOIN (SELECT trackId, MIN(id) AS id FROM asset GROUP BY trackId) firstAsset
                      ON firstAsset.trackId = t.id
                    LEFT JOIN discovery_track_analysis analysis ON analysis.trackId = t.id
                    LEFT JOIN dj_track_prep prep ON prep.trackId = t.id
                    WHERE t.genre IS NOT NULL AND TRIM(t.genre) <> ''
                )
                WHERE bpm > 0 AND (camelot GLOB '[1-9][AB]' OR camelot GLOB '1[0-2][AB]')
                GROUP BY genre
                ORDER BY n DESC, genre ASC
                """)
            return rows.map { (name: $0["genre"], count: $0["n"]) }
        }
    }

    /// Returns the current, displayable musical values for the requested
    /// tracks. Discovery analysis is preferred because it is the shared
    /// library result; DJ prep supplies a user BPM override and remains a
    /// fallback for tracks prepared by the DJ surface before discovery has
    /// completed.
    public func djLoadTrackInfo(trackIds: [Int64]) throws -> [Int64: DJLoadTrackInfo] {
        let ids = Array(Set(trackIds.filter { $0 >= 0 }))
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id AS trackID,
                       a.id AS assetID,
                       analysis.assetId AS analysisAssetID,
                       analysis.bpm AS analysisBPM,
                       analysis.key AS analysisKey,
                       prep.bpmOverride AS bpmOverride,
                       prep.bpm AS prepBPM,
                       prep.camelotKey AS prepKey
                FROM track t
                LEFT JOIN asset a
                  ON a.id = (
                      SELECT MIN(a2.id) FROM asset a2 WHERE a2.trackId = t.id
                  )
                LEFT JOIN discovery_track_analysis analysis
                  ON analysis.trackId = t.id
                LEFT JOIN dj_track_prep prep
                  ON prep.trackId = t.id
                WHERE t.id IN (\(placeholders))
                """, arguments: StatementArguments(ids))

            var result: [Int64: DJLoadTrackInfo] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                let id: Int64 = row["trackID"]
                let assetID: Int64? = row["assetID"]
                let analysisAssetID: Int64? = row["analysisAssetID"]
                let analysisIsCurrent = assetID != nil && assetID == analysisAssetID
                let analysisBPM: Double? = row["analysisBPM"]
                let analysisKey: String? = row["analysisKey"]
                let bpmOverride: Double? = row["bpmOverride"]
                let prepBPM: Double? = row["prepBPM"]
                let prepKey: String? = row["prepKey"]
                result[id] = DJLoadTrackInfo(
                    bpm: bpmOverride ?? (analysisIsCurrent ? analysisBPM : nil) ?? prepBPM,
                    camelotKey: (analysisIsCurrent ? analysisKey : nil) ?? prepKey)
            }
            return result
        }
    }

#if !os(watchOS)
    /// `dj_track_prep` CloudKit records are receive-only now (nothing in this app ever enqueues
    /// one to push — `enqueueDJTrackPrep` was removed as dead code); this only applies an
    /// already-pending remote record from an old app version's sync history. Only `bpm`/
    /// `camelotKey`/`bpmOverride` are real data to accept now; an incoming record's other, now-
    /// unrepresented fields (hot cues, loops, the analysis-payload blob) are simply never read.
    public func applyIncomingDJTrackPrep(_ envelope: DJTrackPrepEnvelope) throws -> Int {
        let ids = try localTrackIds(matching: envelope.trackKeys, trackSyncID: envelope.trackSyncID)
        guard !ids.isEmpty else { return 0 }
        var applied = 0
        try dbQueue.write { db in
            for id in ids {
                var local = try DJTrackPrep.fetchOne(db, key: id) ?? DJTrackPrep(trackId: id)
                let incoming = envelope.prep
                let incomingIsNewer: Bool = {
                    guard incoming.bpm != nil || incoming.camelotKey != nil || incoming.analysisUpdatedAt != nil
                    else { return false }
                    guard let localDate = local.analysisUpdatedAt else { return true }
                    guard let incomingDate = incoming.analysisUpdatedAt else { return false }
                    return incomingDate > localDate
                }()
                if incomingIsNewer {
                    local.bpm = incoming.bpm
                    local.camelotKey = incoming.camelotKey
                    local.analysisUpdatedAt = incoming.analysisUpdatedAt
                    local.bpmOverride = incoming.bpmOverride
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
