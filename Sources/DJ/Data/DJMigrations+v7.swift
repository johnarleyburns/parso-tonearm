import Foundation
import GRDB

extension DJMigrations {
    /// `dj_v7` — opt-in 14-bit CC resolution per binding (M6).
    static func registerV7(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v7") { db in
            try db.alter(table: "midi_binding") { t in
                t.add(column: "resolution", .text).notNull().defaults(to: "sevenBit")
            }
        }
    }
}
