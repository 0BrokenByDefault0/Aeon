import Capacitor
import Foundation

enum LegacyMigrationStore: String, Codable, CaseIterable {
    case albums
    case tracks
    case playlists
    case kv
}

enum LegacyMigrationArtifactKind: String, Codable {
    case artwork
    case audio
}

struct LegacyMigrationInventory: Codable, Equatable {
    let databaseName: String
    let schemaVersion: Int
    let counts: [String: Int]
}

struct LegacyMigrationBlobDescriptor: Codable, Equatable {
    let ownerID: String
    let kind: LegacyMigrationArtifactKind
    let byteLength: Int
    let mediaType: String
    let fileName: String
}

enum LegacyJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LegacyJSONValue])
    case object([String: LegacyJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([LegacyJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: LegacyJSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported legacy value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

struct LegacyMigrationPage: Codable, Equatable {
    let store: LegacyMigrationStore
    let page: Int
    let ids: [String]
    let records: [[String: LegacyJSONValue]]
    let blobs: [LegacyMigrationBlobDescriptor]
    let isLast: Bool
}

struct LegacyMigrationFailure: Error, Codable, Equatable {
    let code: String
    let message: String
}

struct LegacyMigrationInventorySnapshot: Equatable {
    let inventory: LegacyMigrationInventory
    let ids: [LegacyMigrationStore: [String]]
    let blobs: [LegacyMigrationBlobDescriptor]
}

enum LegacyMigrationValidationError: Error, Equatable {
    case alreadyStarted
    case notStarted
    case alreadyFinished
    case invalidDatabase
    case invalidSchema
    case invalidCounts
    case invalidPage
    case pageOutOfOrder
    case pageAfterLast
    case invalidID
    case duplicateID
    case countMismatch
    case invalidBlob
    case incomplete
    case invalidFailure
}

protocol LegacyMigrationReceiving: AnyObject {
    func receive(inventory: LegacyMigrationInventory) throws
    func receive(page: LegacyMigrationPage) throws
    func finishInventory() throws
    func receive(failure: LegacyMigrationFailure) throws
}

final class LegacyMigrationInventoryProbe: LegacyMigrationReceiving {
    typealias Completion = (Result<LegacyMigrationInventorySnapshot, LegacyMigrationFailure>) -> Void

    private struct StoreProgress {
        var nextPage = 0
        var isComplete = false
        var ids: [String] = []
    }

    var onCompletion: Completion?

    private let lock = NSLock()
    private var inventory: LegacyMigrationInventory?
    private var progress: [LegacyMigrationStore: StoreProgress] = [:]
    private var blobs: [LegacyMigrationBlobDescriptor] = []
    private var isFinished = false

    func receive(inventory: LegacyMigrationInventory) throws {
        lock.lock()
        defer { lock.unlock() }
        guard self.inventory == nil, !isFinished else { throw LegacyMigrationValidationError.alreadyStarted }
        guard inventory.databaseName == "isolation-db" else { throw LegacyMigrationValidationError.invalidDatabase }
        guard inventory.schemaVersion >= 1 else { throw LegacyMigrationValidationError.invalidSchema }
        let expectedKeys = Set(LegacyMigrationStore.allCases.map(\.rawValue))
        guard Set(inventory.counts.keys) == expectedKeys,
              inventory.counts.values.allSatisfy({ $0 >= 0 && $0 <= 1_000_000 }) else {
            throw LegacyMigrationValidationError.invalidCounts
        }
        self.inventory = inventory
        progress = Dictionary(uniqueKeysWithValues: LegacyMigrationStore.allCases.map { ($0, StoreProgress()) })
    }

    func receive(page: LegacyMigrationPage) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let inventory else { throw LegacyMigrationValidationError.notStarted }
        guard !isFinished else { throw LegacyMigrationValidationError.alreadyFinished }
        guard page.page >= 0, page.ids.count <= 250, page.records.count == page.ids.count,
              page.blobs.count <= page.ids.count else {
            throw LegacyMigrationValidationError.invalidPage
        }
        guard var storeProgress = progress[page.store] else { throw LegacyMigrationValidationError.invalidPage }
        guard !storeProgress.isComplete else { throw LegacyMigrationValidationError.pageAfterLast }
        guard page.page == storeProgress.nextPage else { throw LegacyMigrationValidationError.pageOutOfOrder }
        guard page.ids.allSatisfy(Self.validID) else { throw LegacyMigrationValidationError.invalidID }
        guard Set(page.ids).count == page.ids.count,
              Set(storeProgress.ids).isDisjoint(with: page.ids) else {
            throw LegacyMigrationValidationError.duplicateID
        }
        guard zip(page.ids, page.records).allSatisfy({ id, record in
            Self.valid(record: record, id: id, store: page.store)
        }) else { throw LegacyMigrationValidationError.invalidPage }
        guard page.blobs.allSatisfy({ Self.valid(blob: $0, ids: page.ids, store: page.store) }) else {
            throw LegacyMigrationValidationError.invalidBlob
        }
        storeProgress.ids.append(contentsOf: page.ids)
        guard storeProgress.ids.count <= inventory.counts[page.store.rawValue, default: -1] else {
            throw LegacyMigrationValidationError.countMismatch
        }
        storeProgress.nextPage += 1
        storeProgress.isComplete = page.isLast
        if page.isLast,
           storeProgress.ids.count != inventory.counts[page.store.rawValue, default: -1] {
            throw LegacyMigrationValidationError.countMismatch
        }
        progress[page.store] = storeProgress
        blobs.append(contentsOf: page.blobs)
    }

    func finishInventory() throws {
        let result: LegacyMigrationInventorySnapshot
        lock.lock()
        guard let inventory else {
            lock.unlock()
            throw LegacyMigrationValidationError.notStarted
        }
        guard !isFinished else {
            lock.unlock()
            throw LegacyMigrationValidationError.alreadyFinished
        }
        guard LegacyMigrationStore.allCases.allSatisfy({ progress[$0]?.isComplete == true }) else {
            lock.unlock()
            throw LegacyMigrationValidationError.incomplete
        }
        isFinished = true
        result = LegacyMigrationInventorySnapshot(
            inventory: inventory,
            ids: progress.mapValues(\.ids),
            blobs: blobs
        )
        let completion = onCompletion
        lock.unlock()
        DispatchQueue.main.async { completion?(.success(result)) }
    }

    func receive(failure: LegacyMigrationFailure) throws {
        guard Self.validCode(failure.code), !failure.message.isEmpty, failure.message.utf8.count <= 512 else {
            throw LegacyMigrationValidationError.invalidFailure
        }
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            throw LegacyMigrationValidationError.alreadyFinished
        }
        isFinished = true
        let completion = onCompletion
        lock.unlock()
        DispatchQueue.main.async { completion?(.failure(failure)) }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains("\0")
    }

    private static func valid(record: [String: LegacyJSONValue], id: String, store: LegacyMigrationStore) -> Bool {
        let idKey = store == .kv ? "k" : "id"
        guard record[idKey] == .string(id), record.values.allSatisfy(validJSON) else { return false }
        switch store {
        case .tracks:
            guard case .string(let albumID)? = record["albumId"], validID(albumID) else { return false }
            if let bytes = record["bytes"] {
                guard case .number(let value) = bytes, value.isFinite, value >= 0, value.rounded() == value else {
                    return false
                }
            }
            if let path = record["path"] {
                guard case .string(let value) = path, safeRelativePath(value) else { return false }
            }
        case .playlists:
            if let items = record["items"] {
                guard case .array(let values) = items, values.allSatisfy(validPlaylistItem) else { return false }
            }
        case .albums, .kv:
            break
        }
        return true
    }

    private static func validJSON(_ value: LegacyJSONValue) -> Bool {
        switch value {
        case .null, .bool: return true
        case .number(let number): return number.isFinite
        case .string(let string): return string.utf8.count <= 1_048_576 && !string.contains("\0")
        case .array(let values): return values.count <= 100_000 && values.allSatisfy(validJSON)
        case .object(let object):
            return object.count <= 100_000 && object.keys.allSatisfy({ $0.utf8.count <= 512 && !$0.contains("\0") })
                && object.values.allSatisfy(validJSON)
        }
    }

    private static func validPlaylistItem(_ value: LegacyJSONValue) -> Bool {
        guard case .object(let item) = value,
              case .string(let albumID)? = item["albumId"],
              case .string(let trackID)? = item["trackId"] else { return false }
        return validID(albumID) && validID(trackID)
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 4_096, !value.contains("\0"),
              !value.hasPrefix("/"), !value.hasPrefix("\\"),
              value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) == nil else { return false }
        let components = value.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func valid(blob: LegacyMigrationBlobDescriptor, ids: [String], store: LegacyMigrationStore) -> Bool {
        guard ids.contains(blob.ownerID), blob.byteLength >= 0,
              blob.mediaType.utf8.count <= 128, blob.fileName.utf8.count <= 512,
              !blob.mediaType.contains("\0"), !blob.fileName.contains("\0"),
              !blob.fileName.contains("/"), !blob.fileName.contains("\\") else { return false }
        switch (store, blob.kind) {
        case (.albums, .artwork), (.tracks, .audio): return true
        default: return false
        }
    }

    private static func validCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80
            && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) }
    }
}

@objc(LegacyMigrationPlugin)
final class LegacyMigrationPlugin: CAPPlugin, CAPBridgedPlugin {
    let identifier = "LegacyMigrationPlugin"
    let jsName = "LegacyMigration"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "reportInventory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reportPage", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "finishInventory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reportFailure", returnType: CAPPluginReturnPromise)
    ]

    private weak var receiver: LegacyMigrationReceiving?

    init(receiver: LegacyMigrationReceiving) {
        self.receiver = receiver
        super.init()
    }

    @objc func reportInventory(_ call: CAPPluginCall) {
        decodeAndReceive(call, as: LegacyMigrationInventory.self) { receiver, value in
            try receiver.receive(inventory: value)
        }
    }

    @objc func reportPage(_ call: CAPPluginCall) {
        decodeAndReceive(call, as: LegacyMigrationPage.self) { receiver, value in
            try receiver.receive(page: value)
        }
    }

    @objc func finishInventory(_ call: CAPPluginCall) {
        guard let receiver else { rejectUnavailable(call); return }
        do {
            try receiver.finishInventory()
            call.resolve()
        } catch {
            reject(call, error: error)
        }
    }

    @objc func reportFailure(_ call: CAPPluginCall) {
        decodeAndReceive(call, as: LegacyMigrationFailure.self) { receiver, value in
            try receiver.receive(failure: value)
        }
    }

    private func decodeAndReceive<T: Decodable>(
        _ call: CAPPluginCall,
        as type: T.Type,
        action: (LegacyMigrationReceiving, T) throws -> Void
    ) {
        guard let receiver else { rejectUnavailable(call); return }
        do {
            let value = try call.decode(type)
            try action(receiver, value)
            call.resolve()
        } catch {
            reject(call, error: error)
        }
    }

    private func rejectUnavailable(_ call: CAPPluginCall) {
        call.reject("Legacy migration receiver unavailable", "legacy_receiver_unavailable")
    }

    private func reject(_ call: CAPPluginCall, error: Error) {
        call.reject("Legacy migration data rejected", "legacy_data_invalid", error)
    }
}
