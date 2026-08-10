import XCTest
import GRDB

@testable import TonearmDJ

final class DJDatabaseTests: XCTestCase {
    func testOpenAtPathAppliesMigrationsWithWAL() throws {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("DJDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        try pool.read { db in
            let applied = try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
            XCTAssertEqual(applied, Set(DJSchema.migrationOrder))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("tonearm-dj.sqlite").path)
        )
    }

    func testCachesDirectoryIsExcludedFromBackup() throws {
        let dir = DJDatabase.cachesDirectory
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
