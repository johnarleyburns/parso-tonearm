import Foundation
import GRDB

extension DJMigrations {
    /// `dj_v10` — C02 (IMPLEMENT_CLAP_PLAN.md), the `PlaylistGenerator`/
    /// `AutoPlaylistModel` rewire onto `SearchService`: `auto_playlist_item.
    /// trackID`, `auto_playlist_rejection.trackID` and `auto_playlist_brief.
    /// seedTrackID` now hold **core** `LibraryStore` track ids (candidates
    /// come from `SearchService.search`, keyed by core `track.id`), not a
    /// DJ-local `track` row created by copying the file into this database.
    /// Same real bug dj_v8/dj_v9 already fixed for `playlist_item.trackID`/
    /// `gig_crate_track.trackID`: the old FK referenced this database's own
    /// (DJ-local) `track` table, which a core id never satisfies — every
    /// `generate()` call failed its `INSERT` outright until this migration.
    ///
    /// Auto-playlist briefs/results/items are DJ-only, not-migrated data
    /// (plan's 2026-09-10 amendment), so this recreates the three tables
    /// empty rather than attempting to translate old DJ-local track ids to
    /// core ids — there is no mapping between the two database files to
    /// translate through. A user's existing generated playlists/briefs are
    /// lost on upgrade, same as every other explicitly-not-migrated DJ-only
    /// table; `auto_playlist_result`/`smart_crate`/`playlist`/`crate_rule`
    /// (none of which store a track id themselves) are untouched.
    static func registerV10(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v10") { db in
            try db.drop(table: "auto_playlist_rejection")
            try db.drop(table: "auto_playlist_item")
            try db.drop(table: "auto_playlist_brief")

            try db.create(table: "auto_playlist_brief") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("prompt", .text).notNull()
                t.column("arcKind", .text).notNull()
                t.column("arcPointsJSON", .text)
                t.column("targetSeconds", .integer)
                t.column("targetTrackCount", .integer)
                t.column("constraintsJSON", .text).notNull()
                // No FK: seedTrackID is a core LibraryStore track id, which
                // lives in a different database file than this one.
                t.column("seedTrackID", .integer)
                t.column("seedCrateID", .integer).references("smart_crate", onDelete: .setNull)
                t.column("randomSeed", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "auto_playlist_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("resultID", .integer).notNull().references("auto_playlist_result", onDelete: .cascade)
                // No FK: trackID is a core LibraryStore track id.
                t.column("trackID", .integer).notNull()
                t.column("position", .integer).notNull()
                t.column("locked", .boolean).notNull().defaults(to: false)
                t.column("targetEnergy", .double).notNull()
                t.column("actualEnergy", .double).notNull()
                t.column("transitionCostIn", .double)
                t.column("semanticScore", .double).notNull()
            }
            try db.create(index: "idx_apl_item_result", on: "auto_playlist_item",
                          columns: ["resultID", "position"])
            try db.create(table: "auto_playlist_rejection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("briefID", .integer).notNull().references("auto_playlist_brief", onDelete: .cascade)
                // No FK: trackID is a core LibraryStore track id.
                t.column("trackID", .integer).notNull()
                t.column("rejectedAt", .datetime).notNull()
            }
            try db.create(index: "idx_apl_reject", on: "auto_playlist_rejection", columns: ["briefID", "trackID"])
        }
    }
}
