import Foundation
import GRDB

extension DJMigrations {
    /// `dj_v9` — C02 (IMPLEMENT_CLAP_PLAN.md), the `GigCrateRepository`
    /// follow-up dj_v8 flagged: `gig_crate_track.trackID` is copied straight
    /// from `playlist_item.trackID` (`promote(playlistID:...)`), which has
    /// been a **core** `LibraryStore` track id since dj_v8 — not a DJ-local
    /// `track` row created by copying the file into this database. The old
    /// `trackID` FK referenced this database's own (DJ-local) `track` table,
    /// which a core id never satisfies (an INSERT of a core-id crate member
    /// fails the FK constraint outright); that FK must go, exactly like
    /// dj_v8 dropped `playlist_item.trackID`'s.
    ///
    /// Gig crates are explicitly DJ-only, not-migrated data (plan's
    /// 2026-09-10 amendment), so this recreates `gig_crate_track` empty
    /// rather than attempting to translate old DJ-local track ids to core
    /// ids — there is no mapping between the two database files to
    /// translate through. A user's existing gig crates lose their track
    /// membership (and must be re-promoted from their source playlist) on
    /// upgrade, same as dj_v8's `playlist_item` reset. `gig_crate` itself
    /// (the crate row / budget / `lastPerformedAt`) is untouched.
    static func registerV9(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v9") { db in
            try db.drop(table: "gig_crate_track")
            try db.create(table: "gig_crate_track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("gigCrateID", .integer).notNull().references("gig_crate", onDelete: .cascade)
                // No FK: trackID is a core LibraryStore track id, which lives
                // in a different database file than this one.
                t.column("trackID", .integer).notNull()
                t.column("position", .integer).notNull()
                t.column("audioCached", .boolean).notNull().defaults(to: false)
                t.column("stemsState", .text).notNull().defaults(to: "pending")
                t.column("stemsBytes", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_gct_crate", on: "gig_crate_track", columns: ["gigCrateID", "position"])
        }
    }
}
