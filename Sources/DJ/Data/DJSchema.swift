import Foundation
import GRDB

public enum DJSchema {
    public static let migrationOrder = ["dj_v1", "dj_v2", "dj_v3", "dj_v4", "dj_v5"]

    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        DJMigrations.registerV1(&migrator)
        DJMigrations.registerV2(&migrator)
        DJMigrations.registerV3(&migrator)
        DJMigrations.registerV4(&migrator)
        DJMigrations.registerV5(&migrator)
        return migrator
    }
}
