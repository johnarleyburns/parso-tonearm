import Foundation
import GRDB

extension DJMigrations {
    /// `dj_v11` — C02 (IMPLEMENT_CLAP_PLAN.md), the `RecordingService.
    /// trackTimelineSnapshots` fix: `mix_track_event.trackID` now holds a
    /// **core** `LibraryStore` track id (`MixTimeline.entries.trackID` is a
    /// core id everywhere — every deck-load path resolves through it,
    /// `DeckLoaderCoreIdentityTests`), not a DJ-local `track` row.
    ///
    /// Same real-bug shape `dj_v8`/`dj_v9`/`dj_v10` already fixed for
    /// `playlist_item.trackID`/`gig_crate_track.trackID`/
    /// `auto_playlist_item.trackID`: the old `references("track", onDelete:
    /// .setNull)` FK pointed at THIS database's own (DJ-local) `track` table,
    /// which a core id essentially never satisfies. Concretely worse than a
    /// display bug — with `foreignKeysEnabled = true` (`DJDatabase.swift`),
    /// every `finalizeRecordingMix` call whose timeline had at least one
    /// entry threw a foreign-key violation on the `mix_track_event` INSERT,
    /// rolled back the whole write transaction, and `RecordingService.
    /// finalize`'s catch block marked the entire mix **corrupt** — not just
    /// "Unknown track": every mix recorded against a core-id deck load has
    /// been failing to finalize at all.
    ///
    /// Recreates `mix_track_event` empty, same as `dj_v10`'s tables: there is
    /// no mapping from an old DJ-local trackID to a core id to translate
    /// existing rows through, and any row written after the DeckLoader
    /// core-id rewire could not have survived the FK violation above anyway
    /// (so there is nothing real from that era to lose). A `mix_track_event`
    /// row inserted before that rewire is display-only tracklist history for
    /// an already-recorded mix; the mix/mix_asset row itself (the actual
    /// audio) is untouched.
    static func registerV11(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v11") { db in
            try db.drop(table: "mix_track_event")
            try db.create(table: "mix_track_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mixID", .integer).notNull().references("mix", onDelete: .cascade)
                // No FK: trackID is a core LibraryStore track id, which lives
                // in a different database file than this one.
                t.column("trackID", .integer)
                t.column("title", .text).notNull()           // snapshot (survives track deletion)
                t.column("artist", .text)
                t.column("deck", .text).notNull()            // A|B
                t.column("startOffsetSec", .double).notNull() // position within the mix
                t.column("bpmAtPlay", .double)
                t.column("camelotAtPlay", .text)
                t.column("position", .integer).notNull()      // 1..n order
            }
            try db.create(index: "idx_mte_mix", on: "mix_track_event", columns: ["mixID", "position"])
        }
    }
}
