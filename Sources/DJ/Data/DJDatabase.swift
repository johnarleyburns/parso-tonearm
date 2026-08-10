import Foundation
import GRDB

public enum DJDatabase {
    public static let databaseFileName = "tonearm-dj.sqlite"

    public static func open() throws -> DatabasePool {
        try open(at: defaultDatabaseURL())
    }

    public static func open(at url: URL) throws -> DatabasePool {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        try DJSchema.migrator().migrate(pool)
        return pool
    }

    public static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("Tonearm", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(databaseFileName)
    }

    /// Derived, regenerable DJ caches (vectors, stems, waveform overflow). Lives
    /// under `Caches/` and is excluded from backup per §13.1 — a correctness
    /// requirement, not housekeeping: every file here is reproducible from the
    /// source audio plus the analysis version (NFR-DET-1).
    public static var cachesDirectory: URL {
        let fm = FileManager.default
        var base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TonearmDJ", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
        return base
    }
}
