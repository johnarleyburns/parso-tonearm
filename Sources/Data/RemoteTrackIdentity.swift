import Foundation
import GRDB

/// The one, centralized definition of a remote track's durable, source-scoped identity.
///
/// Rules (used by browse/play/import, the migration cleanup and tests):
/// 1. A trimmed, nonempty provider-native `remoteNodeID` is the identity.
/// 2. A normalized node path is used only when the caller says the provider's path is a stable,
///    unique key (`pathIsDurable`). No provider opts in today: every provider in
///    `Sources/Remote/Providers` supplies a native node ID (Dropbox/Drive/OneDrive item IDs,
///    Jamendo track IDs, Internet Archive identifier+file, WebDAV/SMB/Subsonic paths-as-IDs), so
///    the path fallback exists but is off by default.
/// 3. A signed/resolved stream URL is never an identity. Placeholder IDs (`now-playing-…`, minted
///    from a transient row ID) are unsafe and yield no identity.
/// 4. Assets without an identity are preserved as-is (never fuzzy-merged by title/duration). The
///    only legacy fallback is an exact same-source stored-locator match, applied by the upsert to
///    rows that have no node ID at all.
/// The value is namespaced by source ID so equal provider values in different libraries never merge.
public struct RemoteTrackIdentity: Hashable, Sendable {
    public let sourceID: Int64
    public let value: String

    /// Identity version prefix; bump if the derivation ever changes.
    static let version = "v1"

    public var key: String { "\(sourceID)|\(value)" }

    public static func canonical(sourceID: Int64, nodeID: String?, nodePath: String? = nil,
                                 pathIsDurable: Bool = false) -> RemoteTrackIdentity? {
        if let id = nodeID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
           !id.hasPrefix("now-playing-") {
            return RemoteTrackIdentity(sourceID: sourceID, value: "\(version):id:\(id)")
        }
        if pathIsDurable, let raw = nodePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, !raw.contains("://"), !raw.contains("?") {
            let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
            guard !parts.isEmpty else { return nil }
            return RemoteTrackIdentity(sourceID: sourceID,
                                       value: "\(version):path:" + parts.joined(separator: "/"))
        }
        return nil
    }
}

/// Atomic get-or-create of the one canonical library track for a remote identity.
enum RemoteTrackUpsert {
    struct Outcome { let trackID: Int64; let created: Bool }

    static func upsert(db: Database, sourceID: Int64, track: Track, asset: Asset,
                       pathIsDurable: Bool = false) throws -> Outcome {
        let identity = RemoteTrackIdentity.canonical(sourceID: sourceID, nodeID: asset.remoteNodeID,
                                                     nodePath: asset.remoteNodePath,
                                                     pathIsDurable: pathIsDurable)
        // A unique-constraint race (another connection committed first) is resolved by retrying
        // the lookup, which then finds the canonical row.
        for attempt in 0..<2 {
            do {
                return try attemptUpsert(db: db, sourceID: sourceID, track: track, asset: asset,
                                         identity: identity)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT && attempt == 0 {
                continue
            }
        }
        throw LibraryStoreError.assetNotFound(track.id ?? -1)
    }

    private static func attemptUpsert(db: Database, sourceID: Int64, track: Track, asset: Asset,
                                      identity: RemoteTrackIdentity?) throws -> Outcome {
        var result: Outcome?
        try db.inSavepoint {
            result = try performUpsert(db: db, sourceID: sourceID, track: track, asset: asset,
                                       identity: identity)
            return .commit
        }
        return result!
    }

    private static func performUpsert(db: Database, sourceID: Int64, track: Track, asset: Asset,
                                      identity: RemoteTrackIdentity?) throws -> Outcome {
        if let identity {
            if let trackID = try Int64.fetchOne(db, sql:
                "SELECT trackId FROM remote_track_identity WHERE sourceId = ? AND identity = ?",
                arguments: [sourceID, identity.value]) {
                try refresh(db: db, trackID: trackID, from: asset)
                return Outcome(trackID: trackID, created: false)
            }
            // A not-yet-mapped row of the same source carrying the same node ID.
            if let trackID = try Int64.fetchOne(db, sql: """
                SELECT a.trackId FROM asset a JOIN track t ON t.id = a.trackId
                WHERE t.sourceId = ? AND a.kind = 'remote' AND a.remoteNodeID = ?
                ORDER BY a.trackId LIMIT 1
                """, arguments: [sourceID, asset.remoteNodeID?.trimmingCharacters(in: .whitespacesAndNewlines)]) {
                try refresh(db: db, trackID: trackID, from: asset)
                try claim(db: db, sourceID: sourceID, identity: identity, trackID: trackID)
                return Outcome(trackID: trackID, created: false)
            }
        }
        // Conservative legacy fallback: exact same-source locator, only for rows with no node ID.
        if let url = asset.remoteURL, let trackID = try Int64.fetchOne(db, sql: """
            SELECT a.trackId FROM asset a JOIN track t ON t.id = a.trackId
            WHERE t.sourceId = ? AND a.kind = 'remote' AND a.remoteURL = ?
              AND (a.remoteNodeID IS NULL OR TRIM(a.remoteNodeID) = '')
            ORDER BY a.trackId LIMIT 1
            """, arguments: [sourceID, url]) {
            if let identity, let nodeID = asset.remoteNodeID {
                try db.execute(sql: "UPDATE asset SET remoteNodeID = ? WHERE trackId = ?",
                               arguments: [nodeID.trimmingCharacters(in: .whitespacesAndNewlines), trackID])
                try claim(db: db, sourceID: sourceID, identity: identity, trackID: trackID)
            }
            return Outcome(trackID: trackID, created: false)
        }
        var newTrack = track
        newTrack.id = nil
        newTrack.sourceId = sourceID
        try newTrack.insert(db)
        guard let trackID = newTrack.id else { throw LibraryStoreError.assetNotFound(-1) }
        var newAsset = asset
        newAsset.id = nil
        newAsset.trackId = trackID
        let trimmed = asset.remoteNodeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        newAsset.remoteNodeID = (trimmed?.isEmpty ?? true) || (trimmed?.hasPrefix("now-playing-") ?? false)
            ? nil : trimmed
        try newAsset.insert(db)
        if let identity { try claim(db: db, sourceID: sourceID, identity: identity, trackID: trackID) }
        try TrackIdentityStore.rebuild(trackId: trackID, db: db)
        return Outcome(trackID: trackID, created: true)
    }

    /// Plain INSERT: a conflicting identity throws a constraint error, which rolls back the
    /// savepoint (no orphan track/asset) and makes `upsert` re-resolve to the canonical row.
    private static func claim(db: Database, sourceID: Int64, identity: RemoteTrackIdentity,
                              trackID: Int64) throws {
        try db.execute(sql:
            "INSERT INTO remote_track_identity (sourceId, identity, trackId) VALUES (?, ?, ?)",
            arguments: [sourceID, identity.value, trackID])
    }

    /// Refresh locator/size/nonsecret content type in place; transient headers are never stored.
    private static func refresh(db: Database, trackID: Int64, from asset: Asset) throws {
        guard var stored = try Asset.filter(Column("trackId") == trackID && Column("kind") == AssetKind.remote.rawValue)
            .fetchOne(db) else { return }
        if let url = asset.remoteURL { stored.remoteURL = url }
        stored.sizeBytes = asset.sizeBytes ?? stored.sizeBytes
        stored.remoteContentType = asset.remoteContentType ?? stored.remoteContentType
        if let path = asset.remoteNodePath, !path.isEmpty { stored.remoteNodePath = path }
        try stored.update(db)
    }
}

/// Consolidates existing duplicate remote tracks (same `RemoteTrackIdentity`) into one survivor.
public enum RemoteTrackConsolidator {
    public struct Report: Equatable, Sendable {
        public var groupsMerged = 0
        public var tracksRemoved = 0
        /// Remote assets without a safe identity, left untouched (count only, privacy-safe).
        public var unidentifiedAssets = 0
    }

    struct InjectedFailure: Error {}

    /// Tables whose rows are handled specially or rebuilt rather than blindly re-pointed.
    private static let skippedTables: Set<String> = ["asset", "track_identity", "remote_track_identity"]

    @discardableResult
    static func run(db: Database, failBeforeDelete: Bool = false) throws -> Report {
        var report = Report()
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.id AS assetId, a.trackId AS trackId, t.sourceId AS sourceId,
                   a.remoteNodeID AS nodeID, a.remoteNodePath AS path
            FROM asset a JOIN track t ON t.id = a.trackId
            WHERE a.kind = 'remote' ORDER BY a.id
            """)
        var groups: [String: (identity: RemoteTrackIdentity, tracks: [Int64])] = [:]
        var order: [String] = []
        var seenTracks = Set<Int64>()
        for row in rows {
            let trackID: Int64 = row["trackId"]
            guard seenTracks.insert(trackID).inserted else { continue }
            guard let identity = RemoteTrackIdentity.canonical(
                sourceID: row["sourceId"], nodeID: row["nodeID"], nodePath: row["path"]) else {
                report.unidentifiedAssets += 1
                continue
            }
            if groups[identity.key] == nil { groups[identity.key] = (identity, []); order.append(identity.key) }
            groups[identity.key]!.tracks.append(trackID)
        }
        let children = try foreignKeyChildren(db: db)
        for key in order {
            guard let group = groups[key] else { continue }
            let tracks = group.tracks
            var survivor = tracks[0]
            if tracks.count > 1 {
                survivor = try chooseSurvivor(db: db, tracks: tracks)
                let losers = tracks.filter { $0 != survivor }
                try db.inSavepoint {
                    try merge(db: db, survivor: survivor, losers: losers, children: children)
                    if failBeforeDelete { throw InjectedFailure() }
                    // GRDB runs migrations with foreign keys off, so cascades are applied by hand.
                    for loser in losers { try deleteLoser(db: db, loser: loser, children: children) }
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO remote_track_identity (sourceId, identity, trackId)
                        VALUES (?, ?, ?)
                        """, arguments: [group.identity.sourceID, group.identity.value, survivor])
                    try TrackIdentityStore.rebuild(trackId: survivor, db: db)
                    return .commit
                }
                report.groupsMerged += 1
                report.tracksRemoved += losers.count
            } else {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO remote_track_identity (sourceId, identity, trackId)
                    VALUES (?, ?, ?)
                    """, arguments: [group.identity.sourceID, group.identity.value, survivor])
            }
        }
        return report
    }

    /// Most user data first, then most complete asset, then lowest track ID (deterministic).
    private static func chooseSurvivor(db: Database, tracks: [Int64]) throws -> Int64 {
        func count(_ sql: String, _ id: Int64) throws -> Int {
            try Int.fetchOne(db, sql: sql, arguments: [id]) ?? 0
        }
        var best: (score: Int, completeness: Int, id: Int64)?
        for id in tracks {
            var score = 0
            score += try count("SELECT COUNT(*) FROM favorite WHERE trackId = ?", id) * 4
            score += try count("SELECT COUNT(*) FROM custom_artwork WHERE trackId = ?", id) * 4
            score += try count("SELECT COUNT(*) FROM playlist_item WHERE trackId = ?", id) * 2
            score += try count("SELECT COUNT(*) FROM play_history WHERE trackId = ?", id)
            score += try count("""
                SELECT COUNT(*) FROM cache_entry c JOIN asset a ON a.id = c.assetId WHERE a.trackId = ?
                """, id)
            let asset = try Asset.filter(Column("trackId") == id).fetchOne(db)
            let completeness = [asset?.remoteURL, asset?.remoteContentType, asset?.remoteNodePath]
                .compactMap { $0 }.count + (asset?.sizeBytes == nil ? 0 : 1)
            let candidate = (score, completeness, id)
            if let current = best {
                if candidate.0 > current.score || (candidate.0 == current.score
                    && (candidate.1 > current.completeness
                        || (candidate.1 == current.completeness && candidate.2 < current.id))) {
                    best = candidate
                }
            } else { best = candidate }
        }
        return best!.id
    }

    private struct Child { let table: String; let column: String; let parent: String; let setNull: Bool }

    private static func foreignKeyChildren(db: Database) throws -> [Child] {
        var result: [Child] = []
        let tables = try String.fetchAll(db, sql:
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        for table in tables where !skippedTables.contains(table) {
            for fk in try Row.fetchAll(db, sql: "SELECT * FROM pragma_foreign_key_list(?)", arguments: [table]) {
                let parent: String = fk["table"]
                if parent == "track" || parent == "asset" {
                    let action: String = fk["on_delete"]
                    result.append(Child(table: table, column: fk["from"], parent: parent,
                                        setNull: action.uppercased() == "SET NULL"))
                }
            }
        }
        return result
    }

    private static func merge(db: Database, survivor: Int64, losers: [Int64], children: [Child]) throws {
        let survivorAssetID = try Int64.fetchOne(db, sql:
            "SELECT id FROM asset WHERE trackId = ? ORDER BY id LIMIT 1", arguments: [survivor])
        // Locator policy: the most recently stored locator in the group refreshes the survivor
        // (rotated URLs expire, so the newest is the likeliest to still work); never null-out.
        if let survivorAssetID {
            for loser in losers.sorted() {
                if let l = try Asset.filter(Column("trackId") == loser && Column("kind") == AssetKind.remote.rawValue)
                    .fetchOne(db), let url = l.remoteURL,
                   var s = try Asset.fetchOne(db, key: survivorAssetID) {
                    s.remoteURL = url
                    s.sizeBytes = l.sizeBytes ?? s.sizeBytes
                    s.remoteContentType = l.remoteContentType ?? s.remoteContentType
                    s.altRemoteURL = l.altRemoteURL ?? s.altRemoteURL
                    s.remoteNodePath = l.remoteNodePath ?? s.remoteNodePath
                    try s.update(db)
                }
            }
        }
        for loser in losers {
            // One membership per playlist: drop a loser's item when the survivor is already there.
            try db.execute(sql: """
                DELETE FROM playlist_item WHERE trackId = ?1
                  AND playlistId IN (SELECT playlistId FROM playlist_item WHERE trackId = ?2)
                """, arguments: [loser, survivor])
            for child in children where child.parent == "track" {
                try db.execute(sql: "UPDATE OR IGNORE \(quote(child.table)) SET \(quote(child.column)) = ? WHERE \(quote(child.column)) = ?",
                               arguments: [survivor, loser])
            }
            if let survivorAssetID {
                let loserAssets = try Int64.fetchAll(db, sql: "SELECT id FROM asset WHERE trackId = ?", arguments: [loser])
                for loserAsset in loserAssets {
                    for child in children where child.parent == "asset" {
                        try db.execute(sql: "UPDATE OR IGNORE \(quote(child.table)) SET \(quote(child.column)) = ? WHERE \(quote(child.column)) = ?",
                                       arguments: [survivorAssetID, loserAsset])
                    }
                }
            }
        }
    }

    private static func deleteLoser(db: Database, loser: Int64, children: [Child]) throws {
        let assets = try Int64.fetchAll(db, sql: "SELECT id FROM asset WHERE trackId = ?", arguments: [loser])
        func clear(_ child: Child, _ id: Int64) throws {
            let t = quote(child.table), c = quote(child.column)
            if child.setNull {
                try db.execute(sql: "UPDATE \(t) SET \(c) = NULL WHERE \(c) = ?", arguments: [id])
            } else {
                try db.execute(sql: "DELETE FROM \(t) WHERE \(c) = ?", arguments: [id])
            }
        }
        for asset in assets { for child in children where child.parent == "asset" { try clear(child, asset) } }
        for child in children where child.parent == "track" { try clear(child, loser) }
        try db.execute(sql: "DELETE FROM asset WHERE trackId = ?", arguments: [loser])
        try db.execute(sql: "DELETE FROM track_identity WHERE trackId = ?", arguments: [loser])
        try db.execute(sql: "DELETE FROM remote_track_identity WHERE trackId = ?", arguments: [loser])
        try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [loser])
    }

    private static func quote(_ name: String) -> String { "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\"" }
}
