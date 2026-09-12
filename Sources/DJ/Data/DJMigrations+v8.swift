import Foundation
import GRDB

extension DJMigrations {
    /// `dj_v8` — C02 (IMPLEMENT_CLAP_PLAN.md): `playlist_item.trackID` now
    /// stores the **core** `LibraryStore` track id directly (the id
    /// `PlaylistCrateImporter` reads from `library.playlistTrackRows`), not a
    /// DJ-local `track` row created by copying the file into this database.
    /// The old `trackID` FK referenced this database's own (DJ-local) `track`
    /// table, which a core id never satisfies — that FK must go.
    ///
    /// Crates are explicitly DJ-only, not-migrated data (plan's 2026-09-10
    /// amendment: "crates/setlists" are intentionally not migrated), so this
    /// recreates `playlist_item` empty rather than attempting to translate
    /// old DJ-local track ids to core ids — there is no mapping between the
    /// two databases to translate through. A user's existing crates are lost
    /// on upgrade, same as every other explicitly-not-migrated DJ-only table;
    /// re-importing a crate from its source playlist recreates it.
    static func registerV8(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v8") { db in
            try db.drop(table: "playlist_item")
            try db.create(table: "playlist_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("playlistID", .integer).notNull().references("playlist", onDelete: .cascade)
                // No FK: trackID is a core LibraryStore track id, which lives
                // in a different database file than this one.
                t.column("trackID", .integer).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(index: "idx_pli_playlist", on: "playlist_item", columns: ["playlistID", "position"])
        }
    }
}
