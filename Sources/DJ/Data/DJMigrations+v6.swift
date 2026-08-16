import Foundation
import GRDB

extension DJMigrations {
    /// `dj_v6` — soft takeover per binding (plan dj-midi-alpha M2). Append-only.
    ///
    /// M2 gives every bound control a takeover mode (`jump`/`pickup`/`scale`);
    /// the choice is a property of the binding, so it must survive the
    /// `midi_binding` round-trip like the transform does. Existing rows get the
    /// conservative default: `jump`, exactly what those profiles did before the
    /// migration existed.
    static func registerV6(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v6") { db in
            try db.alter(table: "midi_binding") { t in
                t.add(column: "takeover", .text).notNull().defaults(to: "jump")
            }
        }
    }
}
