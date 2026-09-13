import Foundation

enum CatalogMigrationError: Error, Equatable {
    case unsupportedSchema(Int)
    case missingMigration(Int)
}

enum CatalogMigrations {
    static func migrate(_ database: CatalogDatabase, through targetVersion: Int = CatalogSchema.currentVersion) throws {
        let current = try database.schemaVersion
        guard current <= targetVersion else { throw CatalogMigrationError.unsupportedSchema(current) }
        guard current < targetVersion else { return }

        for version in (current + 1)...targetVersion {
            let statements: [String]
            switch version {
            case 1: statements = CatalogSchema.versionOne
            case 2: statements = CatalogSchema.versionTwo
            default: throw CatalogMigrationError.missingMigration(version)
            }
            try database.transaction {
                for statement in statements { try database.execute(statement) }
                try database.setSchemaVersion(version)
            }
        }
    }
}
