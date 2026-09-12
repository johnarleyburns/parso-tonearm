import Foundation
import GRDB

public enum DJSchema {
    public static let migrationOrder = ["dj_v1", "dj_v2", "dj_v3", "dj_v4", "dj_v5", "dj_v6", "dj_v7", "dj_v8", "dj_v9", "dj_v10", "dj_v11", "dj_v12"]

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
        DJMigrations.registerV6(&migrator)
        DJMigrations.registerV7(&migrator)
        DJMigrations.registerV8(&migrator)
        DJMigrations.registerV9(&migrator)
        DJMigrations.registerV10(&migrator)
        DJMigrations.registerV11(&migrator)
        DJMigrations.registerV12(&migrator)
        return migrator
    }
}
