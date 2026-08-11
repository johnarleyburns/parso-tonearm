import Foundation
import GRDB

public enum DJSchema {
    public static let migrationOrder = ["dj_v1", "dj_v2", "dj_v3"]

    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        DJMigrations.registerV1(&migrator)
        DJMigrations.registerV2(&migrator)
        DJMigrations.registerV3(&migrator)
        return migrator
    }
}
