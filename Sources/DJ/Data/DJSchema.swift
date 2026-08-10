import Foundation
import GRDB

public enum DJSchema {
    public static let migrationOrder = ["dj_v1"]

    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        DJMigrations.registerV1(&migrator)
        return migrator
    }
}
