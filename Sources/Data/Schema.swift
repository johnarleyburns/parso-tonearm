import Foundation
import GRDB

/// The GRDB migrator, split by migration range across files since a single
/// function body listing every `registerMigration` inline grew past 400
/// lines: `Schema+MigrationsV1toV7.swift`, `Schema+MigrationsV8toV14.swift`,
/// and `Schema+MigrationsV15toV21.swift` hold the versioned migration bodies.
/// `shouldRegister` is called from all three, so it is kept at the implicit
/// internal access level rather than `private`.
public enum Schema {
    static let migrationOrder = [
        "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14",
        "v15", "v16", "v17", "v18", "v19", "v20", "v21"
    ]

    public static func migrator(upTo target: String? = nil) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        registerV1toV7(&migrator, upTo: target)
        registerV8toV14(&migrator, upTo: target)
        registerV15toV21(&migrator, upTo: target)

        return migrator
    }

    static func shouldRegister(_ migration: String, upTo target: String?) -> Bool {
        guard let target else { return true }
        guard let migrationIndex = migrationOrder.firstIndex(of: migration),
            let targetIndex = migrationOrder.firstIndex(of: target)
        else { return false }
        return migrationIndex <= targetIndex
    }
}
