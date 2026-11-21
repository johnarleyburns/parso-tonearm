import Foundation
import GRDB

/// Merges sources that represent the same remote account/endpoint. A Google
/// Drive detach + reattach used to leave two `source` rows; because remote
/// identity is namespaced by source id, every file re-ingested as a new track
/// and showed up twice in Favorites / Jump Back In. The newest source wins so
/// the credential saved by the most recent reattach stays the one in use.
enum SourceConsolidator {
    struct Report: Equatable, Sendable {
        var sourcesMerged = 0
        var albumsMerged = 0
        var remoteGroupsMerged = 0
        var tracksRemoved = 0
    }

    static func run(db: Database) throws -> Report {
        let sources = try Source.fetchAll(db)
        var groups: [String: [Source]] = [:]
        for source in sources {
            guard let key = RemoteSourceIdentity.canonicalKey(for: source) else { continue }
            groups[key, default: []].append(source)
        }

        var report = Report()
        var canonicalIDs = Set<Int64>()
        for (_, group) in groups where group.count > 1 {
            guard let canonical = group.max(by: { ($0.id ?? 0) < ($1.id ?? 0) }),
                  let canonicalID = canonical.id else { continue }
            canonicalIDs.insert(canonicalID)
            for old in group where old.id != canonical.id {
                guard let oldID = old.id else { continue }
                try mergeSource(db: db, old: old, oldID: oldID,
                                canonicalID: canonicalID)
                report.sourcesMerged += 1
            }
        }
        guard !canonicalIDs.isEmpty else { return report }
        try finish(db: db, canonicalIDs: canonicalIDs, report: &report)
        return report
    }

    /// Sources whose provider gave us no account label or endpoint (e.g. a
    /// raw bearer token, or a token response that omitted the account field).
    /// Merge only when the provider-native node IDs prove they are the same
    /// account: at least two shared files and either 100% of the smaller
    /// source for tiny libraries or 80% for normal ones. Two genuinely
    /// different accounts with a few shared files stay separate.
    static func runNodeOverlap(db: Database) throws -> Report {
        let cloudKinds: Set<SourceKind> = [
            .dropbox, .googleDrive, .oneDrive, .pCloud, .box, .yandexDisk,
        ]
        let candidates = try Source.fetchAll(db).filter {
            cloudKinds.contains($0.kind) && RemoteSourceIdentity.canonicalKey(for: $0) == nil
        }
        guard candidates.count > 1 else { return Report() }

        var nodesBySource: [Int64: Set<String>] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.sourceId AS sourceId, a.remoteNodeID AS nodeID
            FROM asset a JOIN track t ON t.id = a.trackId
            WHERE a.kind = 'remote' AND a.remoteNodeID IS NOT NULL
            """)
        for row in rows {
            let sourceID: Int64 = row["sourceId"]
            guard let node: String = row["nodeID"],
                  !node.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            nodesBySource[sourceID, default: []].insert(node)
        }

        var report = Report()
        var canonicalIDs = Set<Int64>()
        for kind in cloudKinds {
            let group = candidates.filter { $0.kind == kind }
            guard group.count > 1 else { continue }
            let ids = group.compactMap(\.id)
            var parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
            func find(_ raw: Int64) -> Int64 {
                var value = raw
                while let next = parent[value], next != value { value = next }
                return value
            }
            func union(_ a: Int64, _ b: Int64) {
                let rootA = find(a), rootB = find(b)
                if rootA != rootB { parent[rootA] = rootB }
            }

            for i in group.indices {
                guard let a = group[i].id, let nodesA = nodesBySource[a], !nodesA.isEmpty else { continue }
                for j in group.indices where j > i {
                    guard let b = group[j].id, let nodesB = nodesBySource[b], !nodesB.isEmpty else { continue }
                    let overlap = nodesA.intersection(nodesB).count
                    let smaller = min(nodesA.count, nodesB.count)
                    guard smaller >= 2 else { continue }
                    let required = smaller >= 5 ? 0.8 : 1.0
                    guard Double(overlap) / Double(smaller) >= required else { continue }
                    union(a, b)
                }
            }

            let clusters = Dictionary(grouping: ids, by: find)
            for (_, cluster) in clusters where cluster.count > 1 {
                guard let canonicalID = cluster.max() else { continue }
                canonicalIDs.insert(canonicalID)
                for oldID in cluster where oldID != canonicalID {
                    guard let old = group.first(where: { $0.id == oldID }) else { continue }
                    try mergeSource(db: db, old: old, oldID: oldID, canonicalID: canonicalID)
                    report.sourcesMerged += 1
                }
            }
        }

        guard !canonicalIDs.isEmpty else { return report }
        try finish(db: db, canonicalIDs: canonicalIDs, report: &report)
        return report
    }

    private static func finish(db: Database, canonicalIDs: Set<Int64>,
                               report: inout Report) throws {
        report.albumsMerged += try mergeAlbums(db: db, sourceIDs: canonicalIDs)
        // Now that duplicate tracks from a reattached source share one source
        // id, the existing source-scoped identity consolidator can merge them
        // (and move favorites/history/playlist rows onto the survivor).
        let remote = try RemoteTrackConsolidator.run(db: db)
        report.remoteGroupsMerged += remote.groupsMerged
        report.tracksRemoved += remote.tracksRemoved

        // Album title/artist may have been filled in from a loser; rebuild the
        // search index for every track now in a merged source.
        let rows = try Row.fetchAll(db, sql: "SELECT id, sourceId FROM track")
        for row in rows {
            let sourceID: Int64 = row["sourceId"]
            guard canonicalIDs.contains(sourceID) else { continue }
            let trackID: Int64 = row["id"]
            try LibraryStore.refreshSearchIndex(trackID: trackID, db: db)
        }
    }

    private static func mergeSource(db: Database, old: Source, oldID: Int64,
                                    canonicalID: Int64) throws {
        // Every table that stores a source id today. Keep this list in sync if
        // another source-scoped table is added; the `merged_source` audit row
        // lets AppState delete the old Keychain credential afterwards.
        try db.execute(sql: "UPDATE track SET sourceId = ? WHERE sourceId = ?",
                       arguments: [canonicalID, oldID])
        try db.execute(sql: "UPDATE album SET sourceId = ? WHERE sourceId = ?",
                       arguments: [canonicalID, oldID])
        try db.execute(sql: "UPDATE playlist SET sourceId = ? WHERE sourceId = ?",
                       arguments: [canonicalID, oldID])
        try db.execute(sql: "UPDATE discovery_import_job SET sourceId = ? WHERE sourceId = ?",
                       arguments: [canonicalID, oldID])
        // Unique per source: keep the canonical source's artwork if it has one,
        // otherwise adopt the duplicate's; the leftover row is deleted below.
        try db.execute(sql: "UPDATE OR IGNORE custom_artwork_source SET sourceId = ? WHERE sourceId = ?",
                       arguments: [canonicalID, oldID])
        try db.execute(sql: "DELETE FROM custom_artwork_source WHERE sourceId = ?",
                       arguments: [oldID])
        // Move identity claims to the surviving source; a duplicate identity
        // already owned by the canonical source is resolved by the track
        // consolidator below.
        try db.execute(sql: """
            INSERT OR IGNORE INTO remote_track_identity (sourceId, identity, trackId)
            SELECT ?, identity, trackId FROM remote_track_identity WHERE sourceId = ?
            """, arguments: [canonicalID, oldID])
        try db.execute(sql: "DELETE FROM remote_track_identity WHERE sourceId = ?",
                       arguments: [oldID])

        try db.execute(sql: """
            INSERT OR REPLACE INTO merged_source (oldSourceId, canonicalSourceId, kind)
            VALUES (?, ?, ?)
            """, arguments: [oldID, canonicalID, old.kind.rawValue])
        try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [oldID])
    }

    /// Albums from the merged sources with the same title (and artist, when
    /// known) become one row; tracks and album artwork are re-pointed first.
    private static func mergeAlbums(db: Database, sourceIDs: Set<Int64>) throws -> Int {
        let albums = try Album.fetchAll(db).filter { sourceIDs.contains($0.sourceId) }
        var groups: [String: [Album]] = [:]
        for album in albums {
            let artist = (album.albumArtist ?? album.artist ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let key = "\(album.sourceId)|\(album.title.lowercased())|\(artist)"
            groups[key, default: []].append(album)
        }

        var merged = 0
        for (_, group) in groups where group.count > 1 {
            let ordered = group.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
            guard var survivor = ordered.first, let survivorID = survivor.id else { continue }
            for loser in ordered.dropFirst() {
                guard let loserID = loser.id else { continue }
                survivor.artist = survivor.artist ?? loser.artist
                survivor.artistId = survivor.artistId ?? loser.artistId
                survivor.albumArtist = survivor.albumArtist ?? loser.albumArtist
                survivor.genre = survivor.genre ?? loser.genre
                survivor.year = survivor.year ?? loser.year
                survivor.artworkId = survivor.artworkId ?? loser.artworkId
                try db.execute(sql: "UPDATE track SET albumId = ? WHERE albumId = ?",
                               arguments: [survivorID, loserID])
                try db.execute(sql: "UPDATE OR IGNORE custom_artwork_album SET albumId = ? WHERE albumId = ?",
                               arguments: [survivorID, loserID])
                try db.execute(sql: "DELETE FROM custom_artwork_album WHERE albumId = ?",
                               arguments: [loserID])
                try db.execute(sql: "DELETE FROM album WHERE id = ?", arguments: [loserID])
                merged += 1
            }
            try survivor.update(db)
        }
        return merged
    }
}
