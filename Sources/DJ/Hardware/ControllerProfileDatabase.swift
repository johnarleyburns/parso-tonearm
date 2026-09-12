import Foundation
import GRDB

/// The dedicated store for `controller_profile`/`midi_mapping`/`midi_binding`
/// (§15, FR-HW-2) — MIDI-profile data only, with no reference to a track,
/// asset, or any other catalog row. It used to live as three tables inside
/// the DJ database (`dj_v5`/`dj_v6`/`dj_v7`); C02 retires that whole database,
/// so this gives the MIDI tables a small, dedicated GRDB pool of their own
/// rather than carrying a `DJLibraryStore` dependency for a `pool` handle it
/// otherwise has no use for.
///
/// `audio_device`/`channel_routing` (also `dj_v5`) are NOT carried over here:
/// `rg` found no reader/writer of either table anywhere in `Sources` — they
/// were dead schema, not live data, so there is nothing to migrate.
public enum ControllerProfileDatabase {
    public static let databaseFileName = "tonearm-midi.sqlite"

    public static func open() throws -> DatabasePool {
        try open(at: defaultDatabaseURL())
    }

    public static func open(at url: URL) throws -> DatabasePool {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        try migrator().migrate(pool)
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

    /// The lazily-opened, process-wide pool `ControllerProfileStore`'s default
    /// arguments resolve against — mirrors `DJLibraryStore.shared` being a
    /// `try!` singleton, since a MIDI settings screen with no database to read
    /// from is not a state the app can usefully continue in either.
    public static let shared: DatabasePool = try! open()

    /// `controller_profile`/`midi_mapping`/`midi_binding`, verbatim from
    /// `dj_v5`/`dj_v6`/`dj_v7` — same DDL, new file, no `track` FK to drop
    /// (these tables never referenced `track`).
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        migrator.registerMigration("midi_v1") { db in
            try db.create(table: "controller_profile") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("vendor", .text)
                t.column("midiEndpointName", .text)
                t.column("active", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "midi_mapping") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileID", .integer).notNull()
                    .references("controller_profile", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "midi_binding") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mappingID", .integer).notNull()
                    .references("midi_mapping", onDelete: .cascade)
                t.column("target", .text).notNull()
                t.column("messageType", .text).notNull()
                t.column("channel", .integer).notNull()
                t.column("number", .integer).notNull()
                t.column("mode", .text).notNull()
                t.column("minValue", .integer).notNull().defaults(to: 0)
                t.column("maxValue", .integer).notNull().defaults(to: 127)
                t.column("invert", .boolean).notNull().defaults(to: false)
                t.column("takeover", .text).notNull().defaults(to: "jump")
                t.column("resolution", .text).notNull().defaults(to: "sevenBit")
            }
            try db.create(index: "idx_binding_mapping", on: "midi_binding",
                          columns: ["mappingID"])
        }
        return migrator
    }
}
