import Foundation
import GRDB

// MARK: - Mutations

extension GigCrateRepository {
    /// Mark a crate performed (§14.3 `lastPerformedAt`): called when the crate
    /// is opened in the workspace. This is the LRU clock FR-ANL-9 evicts by.
    public func markPerformed(crateID: Int64, at date: Date = Date()) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE gig_crate SET lastPerformedAt = ? WHERE id = ?
                """, arguments: [date, crateID])
        }
    }

    /// Set one crate track's stem state + on-disk bytes (§36.4 roll-up). The
    /// §36.3 lane writes `running` before separating and `ready`/`failed` after.
    public func setStemsState(crateID: Int64, trackID: Int64,
                              state: GigCrateStemsState, bytes: Int64 = 0) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE gig_crate_track SET stemsState = ?, stemsBytes = ?
                WHERE gigCrateID = ? AND trackID = ?
                """, arguments: [state.rawValue, bytes, crateID, trackID])
        }
    }

    /// Refresh a track's FR-LIB-8 flag as remote caching progresses (5.6's
    /// cache lane). Never un-pins a file that is present.
    public func setAudioCached(crateID: Int64, trackID: Int64, cached: Bool) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE gig_crate_track SET audioCached = ?
                WHERE gigCrateID = ? AND trackID = ?
                """, arguments: [cached, crateID, trackID])
        }
    }

    /// Re-stamp every crate track's FR-LIB-8 flag from the current disk state —
     /// the honest refresh after a cache purge or a completed download.
    public func refreshAudioCached(crateID: Int64) async throws {
        let rows = try await pool.read { db in
            try GigCrateTrack
                .filter(Column("gigCrateID") == crateID)
                .fetchAll(db)
        }
        var cachedByTrackIDBuilder: [Int64: Bool] = [:]
        for row in rows {
            cachedByTrackIDBuilder[row.trackID] = await isAudioCached(trackID: row.trackID)
        }
        let cachedByTrackID = cachedByTrackIDBuilder
        try await pool.write { db in
            for var row in rows {
                row.audioCached = cachedByTrackID[row.trackID] ?? false
                try row.update(db)
            }
        }
    }
}
