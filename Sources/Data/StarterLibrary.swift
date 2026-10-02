import Foundation
import GRDB

/// The bundled Mood Starter library as an SQLite database ("starter DB") built on the Mac by
/// BuiltInAnalyzer: track metadata, the CLAP embedding, tempo/key/energy, and each track's
/// transition-prep record. It replaces the old JSON index + separate pack.
///
/// The app opens it read-only from the bundle. The small rows are merged into the library in one
/// transaction (`LibraryStore.mergeStarterLibrary`); the transition-prep blobs stay here and are
/// read on demand, so the library database never grows by them. The iPhone build ships
/// `starter-iphone.sqlite` (one waveform bin per second), the Mac `starter-mac.sqlite` (full
/// waveform). Both are build inputs fetched by `scripts/fetch-starter.sh`, not committed.
public final class StarterLibrary: Sendable {
    public static let formatVersion = 1
    #if os(macOS)
    public static let resourceNames = ["starter-mac", "starter-iphone"]
    #else
    public static let resourceNames = ["starter-iphone"]
    #endif

    /// The bundled starter DB, or nil when the build doesn't carry one.
    public static let shared: StarterLibrary? = {
        guard let url = bundledURL else { return nil }
        return try? StarterLibrary(url: url)
    }()

    /// The app bundle's starter DB. Each app carries only its own (project.yml); the shared
    /// package bundle deliberately carries none, or every app and extension would embed both.
    /// `swift test` and BuiltInAnalyzer have no app bundle and read the fetched copy in the
    /// source tree (`Resources/Starter/`, `make starter`).
    public static var bundledURL: URL? {
        for name in resourceNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "sqlite") { return url }
        }
        #if SWIFT_PACKAGE
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Starter", isDirectory: true)
        for name in resourceNames {
            let url = sourceTree.appendingPathComponent("\(name).sqlite")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        #endif
        return nil
    }

    private let dbQueue: DatabaseQueue
    /// Content identity of this starter DB (from `starter_meta`), used to re-merge after an update.
    public let contentVersion: String

    public init(url: URL) throws {
        var config = Configuration()
        config.readonly = true
        config.label = "StarterLibrary"
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        let format = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM starter_meta WHERE key = 'format_version'")
        }
        guard format == String(Self.formatVersion) else {
            throw StarterLibraryError.unsupportedFormat(format ?? "missing")
        }
        contentVersion = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM starter_meta WHERE key = 'content_version'")
        } ?? "unknown"
    }

    public func meta(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM starter_meta WHERE key = ?", arguments: [key])
        }
    }

    public func tracks() throws -> [BuiltInMoodTrack] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, artist, genre, license, license_url, duration, stream_url, artwork_url,
                       bpm, camelot, energy, analysis_scope, emb_dimensions, emb_scale, emb_vector
                FROM starter_track ORDER BY id
                """).map { row in
                BuiltInMoodTrack(
                    id: row["id"], title: row["title"], artist: row["artist"], genre: row["genre"],
                    license: row["license"], licenseURL: row["license_url"], durationSec: row["duration"],
                    streamURL: row["stream_url"], artworkURL: row["artwork_url"],
                    dimensions: row["emb_dimensions"], scale: row["emb_scale"], quantizedVector: row["emb_vector"],
                    bpm: row["bpm"], key: row["camelot"], energy: row["energy"],
                    analysisScopeSeconds: row["analysis_scope"])
            }
        }
    }

    /// The shipped transition-prep payload for the starter track streamed from `streamURL`.
    public func transitionPrep(streamURL: String) throws -> DJTrackPrepPayload? {
        let blob = try dbQueue.read { db in
            try Data.fetchOne(db, sql: """
                SELECT p.payload FROM starter_prep p JOIN starter_track t ON t.id = p.id
                WHERE t.stream_url = ?
                """, arguments: [streamURL])
        }
        return try blob.map(BuiltInTransitionPrepPack.decodeRecord)
    }

    public func preparedCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM starter_prep") ?? 0 }
    }
}

public enum StarterLibraryError: Error, Equatable {
    case unsupportedFormat(String)
}

/// Builds a starter DB (BuiltInAnalyzer `build-starter`).
public enum StarterLibraryWriter {
    public static func create(at url: URL, tracks: [BuiltInMoodTrack],
                              prep: [String: DJTrackPrepPayload], fullWaveform: Bool,
                              meta: [String: String]) throws {
        try? FileManager.default.removeItem(at: url)
        var config = Configuration()
        config.journalMode = .default
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE starter_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                CREATE TABLE starter_track (
                    id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, artist TEXT NOT NULL,
                    genre TEXT NOT NULL, license TEXT NOT NULL, license_url TEXT,
                    duration REAL NOT NULL, stream_url TEXT NOT NULL UNIQUE, artwork_url TEXT,
                    bpm REAL, camelot TEXT, energy REAL, analysis_scope REAL,
                    emb_dimensions INTEGER NOT NULL, emb_scale REAL NOT NULL, emb_vector BLOB NOT NULL);
                CREATE TABLE starter_prep (
                    id TEXT PRIMARY KEY NOT NULL REFERENCES starter_track(id),
                    algorithm TEXT NOT NULL, version INTEGER NOT NULL, payload BLOB NOT NULL);
                """)
            for track in tracks {
                try db.execute(sql: """
                    INSERT INTO starter_track VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        track.id, track.title, track.artist, track.genre, track.license, track.licenseURL,
                        track.durationSec, track.streamURL, track.artworkURL, track.bpm, track.key,
                        track.energy, track.analysisScopeSeconds, track.dimensions, track.scale,
                        track.quantizedVector])
                if let payload = prep[track.id] {
                    try db.execute(sql: "INSERT INTO starter_prep VALUES (?, ?, ?, ?)", arguments: [
                        track.id, payload.algorithmID, payload.version,
                        try BuiltInTransitionPrepPack.encodeRecord(payload, coarseWaveform: !fullWaveform)])
                }
            }
            var allMeta = meta
            allMeta["format_version"] = String(StarterLibrary.formatVersion)
            allMeta["waveform"] = fullWaveform ? "full" : "compact"
            for (key, value) in allMeta {
                try db.execute(sql: "INSERT INTO starter_meta VALUES (?, ?)", arguments: [key, value])
            }
        }
        try queue.vacuum()
    }
}
