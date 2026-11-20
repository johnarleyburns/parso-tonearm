import Foundation
import GRDB

/// Shared track-consolidation machinery used by the remote, local and
/// source-reattachment cleanup passes. Merges user data (favorites, play
/// history, playlist membership, artwork, cache entries) onto a survivor before
/// deleting the losers, so duplicate cleanup never silently loses a user action.
enum TrackMerger {
    struct Child {
        let table: String
        let column: String
        let parent: String
        let setNull: Bool
    }

    /// Tables whose rows are handled specially or rebuilt rather than blindly re-pointed.
    static let skippedTables: Set<String> = ["asset", "track_identity", "remote_track_identity"]

    /// Most user data first, then most complete asset, then lowest track ID (deterministic).
    static func chooseSurvivor(db: Database, tracks: [Int64]) throws -> Int64 {
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
            var completeness = [asset?.remoteURL, asset?.remoteContentType, asset?.remoteNodePath,
                                asset?.relPath, asset?.contentSampleHash]
                .compactMap { $0 }.count
            if asset?.sizeBytes != nil { completeness += 1 }
            if asset?.bookmark != nil { completeness += 2 }
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

    static func foreignKeyChildren(db: Database) throws -> [Child] {
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

    /// Merges `losers` into `survivor` and deletes them. Callers own the
    /// surrounding transaction (usually a savepoint for safety).
    @discardableResult
    static func mergeGroup(db: Database, survivor: Int64, losers: [Int64]) throws -> Int {
        guard !losers.isEmpty else { return 0 }
        let children = try foreignKeyChildren(db: db)
        try db.inSavepoint {
            try merge(db: db, survivor: survivor, losers: losers, children: children)
            for loser in losers { try deleteLoser(db: db, loser: loser, children: children) }
            try TrackIdentityStore.rebuild(trackId: survivor, db: db)
            return .commit
        }
        return losers.count
    }

    static func merge(db: Database, survivor: Int64, losers: [Int64], children: [Child]) throws {
        let survivorAssetID = try Int64.fetchOne(db, sql:
            "SELECT id FROM asset WHERE trackId = ? ORDER BY id LIMIT 1", arguments: [survivor])
        if let survivorAssetID, var s = try Asset.fetchOne(db, key: survivorAssetID) {
            for loser in losers.sorted() {
                guard let l = try Asset.filter(Column("trackId") == loser
                    && Column("kind") == s.kind.rawValue).fetchOne(db) else { continue }
                if s.kind == .remote {
                    // Rotated URLs expire, so the newest stored locator is the
                    // likeliest to work; never null-out a value.
                    if let url = l.remoteURL { s.remoteURL = url }
                    s.sizeBytes = l.sizeBytes ?? s.sizeBytes
                    s.remoteContentType = l.remoteContentType ?? s.remoteContentType
                    s.altRemoteURL = l.altRemoteURL ?? s.altRemoteURL
                    s.remoteNodePath = l.remoteNodePath ?? s.remoteNodePath
                    s.remoteNodeID = s.remoteNodeID ?? l.remoteNodeID
                } else if s.kind == .localRef {
                    // Prefer keeping a playable location; fill missing values
                    // from whichever duplicate still resolves.
                    s.bookmark = s.bookmark ?? l.bookmark
                    s.relPath = s.relPath ?? l.relPath
                    s.remoteURL = s.remoteURL ?? l.remoteURL
                    s.altRemoteURL = s.altRemoteURL ?? l.altRemoteURL
                    s.sizeBytes = s.sizeBytes ?? l.sizeBytes
                    s.contentSampleHash = s.contentSampleHash ?? l.contentSampleHash
                    s.needsReimport = s.needsReimport && l.needsReimport
                    if l.unsupportedReason == nil { s.unsupportedReason = nil }
                }
            }
            try s.update(db)
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

    static func deleteLoser(db: Database, loser: Int64, children: [Child]) throws {
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
        try db.execute(sql: "DELETE FROM track_fts WHERE rowid = ?", arguments: [loser])
        try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [loser])
    }

    static func quote(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
