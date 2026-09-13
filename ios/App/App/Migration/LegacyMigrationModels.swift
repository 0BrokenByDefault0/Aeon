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

    var artifactID: String { "\(kind.rawValue):\(ownerID)" }
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
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported legacy value") }
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

    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var arrayValue: [LegacyJSONValue]? { if case .array(let value) = self { return value }; return nil }
    var objectValue: [String: LegacyJSONValue]? { if case .object(let value) = self { return value }; return nil }
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
    let records: [LegacyMigrationStore: [[String: LegacyJSONValue]]]
    let blobs: [LegacyMigrationBlobDescriptor]
}

struct LegacyMigrationArtifactStart: Codable, Equatable {
    let runID: String
    let artifactID: String
    let ownerID: String
    let kind: LegacyMigrationArtifactKind
    let byteLength: Int
    let mediaType: String
    let fileName: String
}

struct LegacyMigrationArtifactChunk: Codable, Equatable {
    let runID: String
    let artifactID: String
    let sequence: Int
    let offset: Int
    let bytesBase64: String
    let crc32: UInt32
}

struct LegacyMigrationArtifactFinish: Codable, Equatable {
    let runID: String
    let artifactID: String
    let byteLength: Int
    let crc32: UInt32
}

struct LegacyMigrationArtifactResume: Equatable {
    let nextOffset: Int
    let nextSequence: Int
    let complete: Bool
}

enum LegacyMigrationPhase: String, Codable, Equatable {
    case staging
    case artwork
    case publishing
    case audio
    case complete
    case failed
}

struct LegacyMigrationProgress: Equatable {
    let phase: LegacyMigrationPhase
    let completedArtifacts: Int
    let totalArtifacts: Int
    let catalogueReady: Bool
    let sourceComplete: Bool
    let message: String

    var fraction: Double {
        guard totalArtifacts > 0 else { return sourceComplete ? 1 : 0 }
        return min(1, max(0, Double(completedArtifacts) / Double(totalArtifacts)))
    }
}

struct LegacyArtifactStage: Codable, Equatable {
    let artifactID: String
    let receivedBytes: Int
    let nextSequence: Int
    let expectedBytes: Int
    let wholeCRC32: UInt32?
    let storedReference: String?
}

struct LegacyPlaylistImport {
    let playlist: CatalogPlaylist
    let trackIDs: [String]
}

struct LegacyListeningImport {
    let trackID: String
    let playCount: Int64
}

struct LegacyCatalogImport {
    let albums: [(CatalogAlbum, [CatalogTrack])]
    let playlists: [LegacyPlaylistImport]
    let listening: [LegacyListeningImport]
    let settings: [String: Data]
}

enum LegacyCRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        update(&crc, with: data)
        return crc ^ UInt32.max
    }

    static func checksum(fileURL: URL, chunkSize: Int = 512 * 1_024) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var crc = UInt32.max
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty { update(&crc, with: data) }
        return crc ^ UInt32.max
    }

    private static func update(_ crc: inout UInt32, with data: Data) {
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB88320 & (0 &- (crc & 1))) }
        }
    }
}

protocol LegacyMigrationArtifactReceiving: AnyObject {
    func begin(artifact: LegacyMigrationArtifactStart) throws -> LegacyMigrationArtifactResume
    func receive(chunk: LegacyMigrationArtifactChunk) throws -> LegacyMigrationArtifactResume
    func finish(artifact: LegacyMigrationArtifactFinish) throws
    func receive(failure: LegacyMigrationFailure)
}
