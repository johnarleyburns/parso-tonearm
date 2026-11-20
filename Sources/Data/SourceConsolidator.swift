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

        report.albumsMerged = try mergeAlbums(db: db, sourceIDs: canonicalIDs)
        // Now that duplicate tracks from a reattached source share one source
        // id, the existing source-scoped identity consolidator can merge them
        // (and move favorites/history/playlist rows onto the survivor).
        let remote = try RemoteTrackConsolidator.run(db: db)
        report.remoteGroupsMerged = remote.groupsMerged
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
        return report
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
