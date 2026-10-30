import Foundation
import GRDB

/// One Starter Pack track as the versioned starter catalog (`starter-v4.sqlite`) states it.
struct StarterCatalogEntry: Equatable, Sendable {
    /// The catalog's own id (`jamendo-<track id>`).
    let catalogID: String
    /// The pack's track id (the `<track id>` part).
    let trackID: String
    let title: String
    let artist: String
    let genre: String
    /// Catalog artwork URL; absent or invalid is non-fatal and never affects audio playback.
    let artworkURL: URL?
    let durationSeconds: Double
    let bpm: Double
    /// Normalised Camelot code, e.g. `8A`.
    let camelot: String
}

enum StarterCatalogError: Error, Equatable {
    case unavailable
    case incompatibleVersion(String)
    case missing([String])
    case duplicated([String])
    case invalid(id: String, reason: String)
}

/// Read-only view of the existing starter catalog. It copies nothing: callers resolve ids and persist
/// the answer, and every id must resolve to exactly one valid row or nothing is returned.
struct StarterCatalogAdapter: Sendable {
    /// `starter_meta.format_version` this adapter understands (shared with `StarterLibrary`).
    static let supportedFormat = String(StarterLibrary.formatVersion)
    static let catalogIDPrefix = "jamendo-"
    static let bpmRange = 30.0...300.0

    let url: URL

    /// The catalog bundled with the app (or fetched into the source tree for `swift test`).
    static func bundled() throws -> StarterCatalogAdapter {
        guard let url = StarterLibrary.bundledURL else { throw StarterCatalogError.unavailable }
        return StarterCatalogAdapter(url: url)
    }

    /// Content identity of the catalog, for provenance.
    func contentVersion() throws -> String {
        try read { db in try Self.contentVersion(db) }
    }

    /// Resolves `trackIDs` (in the given order). Throws without a partial result.
    func resolve(trackIDs: [String]) throws -> [StarterCatalogEntry] {
        try read { db in
            var entries: [StarterCatalogEntry] = [], missing: [String] = [], duplicated: [String] = []
            for trackID in trackIDs {
                let catalogID = Self.catalogIDPrefix + trackID
                let rows = try Row.fetchAll(db, sql: "SELECT id, title, artist, genre, duration, NULL AS artwork_url, bpm, camelot FROM starter_track WHERE id = ?",
                                            arguments: [catalogID])
                guard let row = rows.first else { missing.append(catalogID); continue }
                if rows.count > 1 { duplicated.append(catalogID); continue }
                entries.append(try Self.entry(row, catalogID: catalogID, trackID: trackID))
            }
            if !missing.isEmpty { throw StarterCatalogError.missing(missing) }
            if !duplicated.isEmpty { throw StarterCatalogError.duplicated(duplicated) }
            if Set(trackIDs).count != trackIDs.count {
                throw StarterCatalogError.duplicated(Dictionary(grouping: trackIDs, by: { $0 }).filter { $1.count > 1 }
                    .keys.sorted().map { Self.catalogIDPrefix + $0 })
            }
            return entries
        }
    }

    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        var config = Configuration()
        config.readonly = true
        config.label = "StarterCatalogAdapter"
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        return try queue.read { db in
            let format = try String.fetchOne(db, sql: "SELECT value FROM starter_meta WHERE key = 'format_version'")
            guard format == Self.supportedFormat else { throw StarterCatalogError.incompatibleVersion(format ?? "missing") }
            return try body(db)
        }
    }

    private static func contentVersion(_ db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT value FROM starter_meta WHERE key = 'content_version'") ?? "unknown"
    }

    private static func entry(_ row: Row, catalogID: String, trackID: String) throws -> StarterCatalogEntry {
        func invalid(_ reason: String) -> StarterCatalogError { .invalid(id: catalogID, reason: reason) }
        let title = (row["title"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw invalid("title") }
        let artist = (row["artist"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !artist.isEmpty else { throw invalid("artist") }
        let artwork = (row["artwork_url"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artworkURL = artwork.isEmpty ? nil : URL(string: artwork).flatMap { $0.scheme != nil ? $0 : nil }
        let genre = (row["genre"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !genre.isEmpty else { throw invalid("genre") }
        guard let duration = row["duration"] as Double?, duration.isFinite, duration > 0 else { throw invalid("duration") }
        guard let bpm = row["bpm"] as Double?, bpm.isFinite, bpmRange.contains(bpm) else { throw invalid("bpm") }
        guard let rawKey = row["camelot"] as String?, BlendTraits.parseCamelot(rawKey) != nil else { throw invalid("camelot") }
        return StarterCatalogEntry(catalogID: catalogID, trackID: trackID, title: title, artist: artist, genre: genre,
                                   artworkURL: artworkURL, durationSeconds: duration,
                                   bpm: bpm, camelot: rawKey.trimmingCharacters(in: .whitespaces).uppercased())
    }
}
