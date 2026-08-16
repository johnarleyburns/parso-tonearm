import Foundation
import GRDB

extension DJMigrations {
    /// `dj_v5` — hardware: MIDI mapping and audio-device memory (§15, §44,
    /// FR-HW-1/2/4, plan 6.5). Append-only, like every migration before it.
    ///
    /// The four tables are §15's DDL verbatim. They land together because they
    /// describe one thing from two sides: `audio_device`/`channel_routing`
    /// remember what a device *is* and where its channels go, and
    /// `controller_profile`/`midi_mapping`/`midi_binding` remember what its
    /// controls *do*. A user who plugs the same controller in next week should
    /// find both restored without touching anything (§44.2, §44.4).
    static func registerV5(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v5") { db in

            // ---- audio_device (observed AVAudioSession routes; FR-HW-4) ----
            // On iOS the route is observed, never selected (§44.2). This is a
            // memory of devices we have seen, so their cue routing and buffer
            // preference come back automatically next time.
            try db.create(table: "audio_device") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uid", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("portType", .text).notNull()
                t.column("outputChannels", .integer).notNull()
                t.column("sampleRate", .double)
                t.column("grantedBufferDuration", .double)
                t.column("measuredOutputLatency", .double)
                t.column("cueMode", .text).notNull().defaults(to: "splitOutput")
                t.column("lastSeenAt", .datetime).notNull()
            }

            // ---- channel_routing (role → device channel map; FR-HW-1) ----
            try db.create(table: "channel_routing") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("deviceUID", .text).notNull()
                t.column("role", .text).notNull()
                t.column("channelLow", .integer).notNull()
                t.column("channelHigh", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_routing_device", on: "channel_routing",
                          columns: ["deviceUID"])

            // ---- controller_profile (a mapped MIDI controller; FR-HW-2) ----
            try db.create(table: "controller_profile") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("vendor", .text)
                t.column("midiEndpointName", .text)
                t.column("active", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }

            // ---- midi_mapping (a named mapping set belonging to a profile) ----
            try db.create(table: "midi_mapping") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileID", .integer).notNull()
                    .references("controller_profile", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // ---- midi_binding (single control → target; FR-HW-2/3) ----
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
            }
            try db.create(index: "idx_binding_mapping", on: "midi_binding",
                          columns: ["mappingID"])
        }
    }
}
