import Foundation
import GRDB

/// Small repository over the four auto-playlist tables + `playlist`/`playlist_item`
/// (plan M3 commit 3.3, §14.3): persist brief + result + items + rejections in one
/// transaction, load a brief's latest result with its items, and save a generated
/// sequence as a static playlist (FR-PLIST-7).
public struct AutoPlaylistRepository: Sendable {
    public let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - Persist

    /// Insert (or update) a brief, insert a result and its items — one transaction,
    /// so a crash or a failed insert leaves no half-written generation (NFR-REL-1).
    @discardableResult
    public func save(brief: AutoPlaylistBrief, result: AutoPlaylistResult,
                     items: [AutoPlaylistItem]) throws -> (briefID: Int64, resultID: Int64) {
        try pool.write { db in
            var storedBrief = brief
            if storedBrief.id == nil {
                try storedBrief.insert(db)
            } else {
                try storedBrief.update(db)
            }
            guard let briefID = storedBrief.id else { throw AutoPlaylistError.persistFailed }
            var storedResult = result
            storedResult.briefID = briefID
            try storedResult.insert(db)
            guard let resultID = storedResult.id else { throw AutoPlaylistError.persistFailed }
            for var item in items {
                item.resultID = resultID
                try item.insert(db)
            }
            return (briefID, resultID)
        }
    }

    // MARK: - Briefs

    public func brief(id: Int64) throws -> AutoPlaylistBrief? {
        try pool.read { db in
            try AutoPlaylistBrief.fetchOne(db, key: id)
        }
    }

    public func briefs() throws -> [AutoPlaylistBrief] {
        try pool.read { db in
            try AutoPlaylistBrief.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    // MARK: - Results

    /// A brief's latest result with its items in position order.
    public func latestResult(for briefID: Int64) throws -> (result: AutoPlaylistResult,
                                                            items: [AutoPlaylistItem])? {
        try pool.read { db in
            guard let result = try AutoPlaylistResult
                .filter(Column("briefID") == briefID)
                .order(Column("generatedAt").desc, Column("id").desc)
                .fetchOne(db) else { return nil }
            let items = try AutoPlaylistItem
                .filter(Column("resultID") == result.id)
                .order(Column("position"))
                .fetchAll(db)
            return (result, items)
        }
    }

    public func results(for briefID: Int64) throws -> [AutoPlaylistResult] {
        try pool.read { db in
            try AutoPlaylistResult
                .filter(Column("briefID") == briefID)
                .order(Column("generatedAt").desc)
                .fetchAll(db)
        }
    }

    // MARK: - Rejections (§28A.4)

    /// Add rejections, de-duplicating against what is already stored (the dj_v1
    /// index is non-unique, §14.3 verbatim — the semantic uniqueness lives here).
    public func upsertRejections(briefID: Int64, trackIDs: [Int64]) throws {
        try pool.write { db in
            let existing = Set(try AutoPlaylistRejection
                .filter(Column("briefID") == briefID)
                .fetchAll(db)
                .compactMap(\.trackID))
            for trackID in trackIDs where !existing.contains(trackID) {
                var rejection = AutoPlaylistRejection(briefID: briefID, trackID: trackID,
                                                      rejectedAt: Date())
                try rejection.insert(db)
            }
        }
    }

    public func rejections(for briefID: Int64) throws -> [Int64] {
        try pool.read { db in
            try AutoPlaylistRejection
                .filter(Column("briefID") == briefID)
                .fetchAll(db)
                .compactMap(\.trackID)
        }
    }

    // MARK: - Static save (FR-PLIST-7)

    /// Save the generated sequence as a static `playlist` and link it on the
    /// brief's latest result, in one transaction.
    @discardableResult
    public func savePlaylist(title: String, briefID: Int64,
                             slots: [SequencedSlot]) throws -> Int64 {
        try pool.write { db in
            let now = Date()
            var playlist = DJPlaylist(syncID: UUID().uuidString,
                                      title: title,
                                      kind: "manual",
                                      createdAt: now,
                                      updatedAt: now)
            try playlist.insert(db)
            guard let playlistID = playlist.id else { throw AutoPlaylistError.persistFailed }
            for (position, slot) in slots.enumerated() {
                var item = DJPlaylistItem(playlistID: playlistID,
                                          trackID: slot.trackID,
                                          position: position)
                try item.insert(db)
            }
            if let latest = try AutoPlaylistResult
                .filter(Column("briefID") == briefID)
                .order(Column("generatedAt").desc, Column("id").desc)
                .fetchOne(db) {
                var updated = latest
                updated.playlistID = playlistID
                try updated.update(db)
            }
            return playlistID
        }
    }
}

public enum AutoPlaylistError: Error {
    case persistFailed
}
