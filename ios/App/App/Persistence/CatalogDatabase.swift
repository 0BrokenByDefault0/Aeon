import Foundation
import SQLite3

enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var int64: Int64? {
        switch self {
        case .integer(let value): return value
        case .real(let value):
            guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else { return nil }
            return Int64(value)
        case .null, .text, .blob: return nil
        }
    }

    var double: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        case .null, .text, .blob: return nil
        }
    }

    var string: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    var data: Data? {
        guard case .blob(let value) = self else { return nil }
        return value
    }
}

struct CatalogRow: Equatable {
    private let values: [String: SQLiteValue]

    init(values: [String: SQLiteValue]) { self.values = values }

    subscript(_ column: String) -> SQLiteValue? { values[column] }
    var firstValue: SQLiteValue? { values.values.first }
    func string(_ column: String) -> String? { values[column]?.string }
    func int64(_ column: String) -> Int64? { values[column]?.int64 }
    func int(_ column: String) -> Int? { values[column]?.int64.map(Int.init) }
    func double(_ column: String) -> Double? { values[column]?.double }
    func data(_ column: String) -> Data? { values[column]?.data }
}

struct CatalogRecovery: Equatable {
    let originalDatabaseURL: URL
    let quarantineDirectory: URL
    let preservedFiles: [String]
}

enum CatalogDatabaseError: Error, Equatable {
    case sqlite(code: Int32, message: String)
    case invalidResult(String)
    case corruptionDetected(String)
    case recoveryRequired(CatalogRecovery)
}

final class CatalogDatabase {
    static let filename = "catalog.sqlite3"
    static let maximumPageSize = 250

    let url: URL
    let recoveryDirectory: URL

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "app.aeon.catalog.sqlite", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var handle: OpaquePointer?

    init(
        url: URL,
        recoveryDirectory: URL,
        fileManager: FileManager = .default,
        targetSchemaVersion: Int = CatalogSchema.currentVersion
    ) throws {
        self.url = url
        self.recoveryDirectory = recoveryDirectory
        self.fileManager = fileManager
        queue.setSpecific(key: queueKey, value: 1)

        let existed = fileManager.fileExists(atPath: url.path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try serialized {
                try openHandle()
                if existed { try verifyIntegrity() }
                try configureConnection()
                try CatalogMigrations.migrate(self, through: targetSchemaVersion)
            }
        } catch {
            closeHandle()
            guard existed, Self.isCorruption(error) else { throw error }
            let recovery = try quarantineDamagedDatabase()
            throw CatalogDatabaseError.recoveryRequired(recovery)
        }
    }

    convenience init(rootURL: URL, fileManager: FileManager = .default) throws {
        let catalogDirectory = rootURL.appendingPathComponent("Catalog", isDirectory: true)
        try self.init(
            url: catalogDirectory.appendingPathComponent(Self.filename, isDirectory: false),
            recoveryDirectory: rootURL.appendingPathComponent("Recovery", isDirectory: true),
            fileManager: fileManager
        )
    }

    deinit {
        serialized { closeHandle() }
    }

    var schemaVersion: Int {
        get throws {
            let value = try scalar("PRAGMA user_version")?.int64 ?? 0
            return Int(value)
        }
    }

    var journalMode: String {
        get throws { try scalar("PRAGMA journal_mode")?.string ?? "" }
    }

    var foreignKeysEnabled: Bool {
        get throws { try scalar("PRAGMA foreign_keys")?.int64 == 1 }
    }

    func tableNames() throws -> [String] {
        try query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).compactMap { $0.string("name") }
    }

    func indexNames() throws -> [String] {
        try query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).compactMap { $0.string("name") }
    }

    @discardableResult
    func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        try serialized {
            let statement = try prepare(sql, bindings: bindings)
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else { throw sqliteError() }
            return Int(sqlite3_changes(try requiredHandle()))
        }
    }

    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [CatalogRow] {
        try serialized {
            let statement = try prepare(sql, bindings: bindings)
            defer { sqlite3_finalize(statement) }
            var rows: [CatalogRow] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: rows.append(materialize(statement))
                case SQLITE_DONE: return rows
                default: throw sqliteError()
                }
            }
        }
    }

    func scalar(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> SQLiteValue? {
        try query(sql, bindings).first?.firstValue
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try serialized {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                _ = try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func checkpoint() throws {
        _ = try query("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func close() {
        serialized { closeHandle() }
    }

    func setSchemaVersion(_ version: Int) throws {
        guard version >= 0, version <= CatalogSchema.currentVersion else {
            throw CatalogMigrationError.unsupportedSchema(version)
        }
        try execute("PRAGMA user_version = \(version)")
    }

    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    private func openHandle() throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        handle = database
        guard result == SQLITE_OK else { throw sqliteError(code: result) }
        sqlite3_extended_result_codes(database, 1)
    }

    private func configureConnection() throws {
        guard sqlite3_busy_timeout(try requiredHandle(), 5_000) == SQLITE_OK else { throw sqliteError() }
        try execute("PRAGMA foreign_keys = ON")
        guard try foreignKeysEnabled else { throw CatalogDatabaseError.invalidResult("foreign_keys") }
        guard try scalar("PRAGMA journal_mode = WAL")?.string?.lowercased() == "wal" else {
            throw CatalogDatabaseError.invalidResult("journal_mode")
        }
        try execute("PRAGMA synchronous = NORMAL")
    }

    private func verifyIntegrity() throws {
        guard try scalar("PRAGMA quick_check(1)")?.string?.lowercased() == "ok" else {
            throw CatalogDatabaseError.corruptionDetected("quick_check")
        }
    }

    private func prepare(_ sql: String, bindings: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(try requiredHandle(), sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw sqliteError(code: result) }
        do {
            guard sqlite3_bind_parameter_count(statement) == Int32(bindings.count) else {
                throw CatalogDatabaseError.invalidResult("binding_count")
            }
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let bindResult: Int32
                switch value {
                case .null:
                    bindResult = sqlite3_bind_null(statement, index)
                case .integer(let number):
                    bindResult = sqlite3_bind_int64(statement, index, number)
                case .real(let number):
                    bindResult = sqlite3_bind_double(statement, index, number)
                case .text(let string):
                    bindResult = sqlite3_bind_text(statement, index, string, -1, Self.transientDestructor)
                case .blob(let data):
                    bindResult = data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transientDestructor)
                    }
                }
                guard bindResult == SQLITE_OK else { throw sqliteError(code: bindResult) }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func materialize(_ statement: OpaquePointer) -> CatalogRow {
        var values: [String: SQLiteValue] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values[name] = .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                values[name] = .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, index))
                if count == 0 { values[name] = .blob(Data()) }
                else if let bytes = sqlite3_column_blob(statement, index) {
                    values[name] = .blob(Data(bytes: bytes, count: count))
                } else { values[name] = .null }
            default:
                values[name] = .null
            }
        }
        return CatalogRow(values: values)
    }

    private func requiredHandle() throws -> OpaquePointer {
        guard let handle else { throw CatalogDatabaseError.invalidResult("closed_database") }
        return handle
    }

    private func sqliteError(code: Int32? = nil) -> CatalogDatabaseError {
        let resolvedCode = code ?? handle.map(sqlite3_extended_errcode) ?? SQLITE_MISUSE
        let message = handle.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "SQLite error"
        return .sqlite(code: resolvedCode, message: message)
    }

    private func closeHandle() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    private static func isCorruption(_ error: Error) -> Bool {
        if case CatalogDatabaseError.corruptionDetected = error { return true }
        guard case CatalogDatabaseError.sqlite(let code, _) = error else { return false }
        return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
            || (code & 0xFF) == SQLITE_CORRUPT || (code & 0xFF) == SQLITE_NOTADB
    }

    private func quarantineDamagedDatabase() throws -> CatalogRecovery {
        let stamp = String(Int64(Date().timeIntervalSince1970 * 1_000))
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let directory = recoveryDirectory.appendingPathComponent("catalog-\(stamp)-\(suffix)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var preserved: [String] = []
        for source in [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] {
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = directory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            try fileManager.moveItem(at: source, to: destination)
            preserved.append(source.lastPathComponent)
        }
        return CatalogRecovery(
            originalDatabaseURL: url,
            quarantineDirectory: directory,
            preservedFiles: preserved.sorted()
        )
    }
}
