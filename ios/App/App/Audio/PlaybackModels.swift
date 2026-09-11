import Foundation

enum PlaybackIntent: String, Codable {
    case playing
    case paused
}

enum ReplayGainMode: String, Codable {
    case off
    case album
    case track
}

enum AudioRouteKind: String, Codable {
    case speaker
    case wired
    case bluetooth
    case airPlay
    case usb
    case unknown
}

enum MediaReference: Codable, Equatable {
    case native(relativePath: String)
    case externalBookmark(Data)
    case legacyBlob(trackID: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case relativePath
        case bookmark
        case trackID
    }

    private enum Kind: String, Codable {
        case native
        case externalBookmark
        case legacyBlob
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .native:
            self = .native(relativePath: try container.decode(String.self, forKey: .relativePath))
        case .externalBookmark:
            self = .externalBookmark(try container.decode(Data.self, forKey: .bookmark))
        case .legacyBlob:
            self = .legacyBlob(trackID: try container.decode(String.self, forKey: .trackID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .native(let relativePath):
            try container.encode(Kind.native, forKey: .type)
            try container.encode(relativePath, forKey: .relativePath)
        case .externalBookmark(let bookmark):
            try container.encode(Kind.externalBookmark, forKey: .type)
            try container.encode(bookmark, forKey: .bookmark)
        case .legacyBlob(let trackID):
            try container.encode(Kind.legacyBlob, forKey: .type)
            try container.encode(trackID, forKey: .trackID)
        }
    }
}

struct QueueItem: Codable, Equatable {
    let trackID: String
    let albumID: String
    let mediaRef: MediaReference
}

struct SourceFormatDescriptor: Codable, Equatable {
    let codec: String?
    let container: String?
    let sampleRate: Double?
    let channelCount: Int?
    let bitDepth: Int?
    let duration: Double?
}

struct RouteDescriptor: Codable, Equatable {
    let kind: AudioRouteKind
    let name: String
    let sampleRate: Double?
    let channelCount: Int?
}

struct OutputFormatDescriptor: Codable, Equatable {
    let sampleRate: Double
    let channelCount: Int
    let route: RouteDescriptor
}

struct EQBand: Codable, Equatable {
    let frequency: Double
    let q: Double
    let gainDB: Double
}

struct PlaybackSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let version: UInt64
    let trackID: String?
    let queueRevision: UInt64
    let queue: [QueueItem]
    let queueIndex: Int?
    let position: Double
    let intent: PlaybackIntent
    let replayGainMode: ReplayGainMode
    let replayGainPreampDB: Double
    let masterVolume: Double
    let eqEnabled: Bool
    let eqBands: [EQBand]
    let route: RouteDescriptor?
    let sourceFormat: SourceFormatDescriptor?
    let outputFormat: OutputFormatDescriptor?
    let timestamp: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, version, trackID, queueRevision, queue, queueIndex, position, intent
        case replayGainMode, replayGainPreampDB, masterVolume, eqEnabled, eqBands
        case route, sourceFormat, outputFormat, timestamp
    }

    init(
        schemaVersion: Int = 1,
        version: UInt64,
        trackID: String?,
        queueRevision: UInt64,
        queue: [QueueItem],
        queueIndex: Int?,
        position: Double,
        intent: PlaybackIntent,
        replayGainMode: ReplayGainMode,
        replayGainPreampDB: Double,
        masterVolume: Double,
        eqEnabled: Bool,
        eqBands: [EQBand],
        route: RouteDescriptor?,
        sourceFormat: SourceFormatDescriptor?,
        outputFormat: OutputFormatDescriptor?,
        timestamp: Date
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.trackID = trackID
        self.queueRevision = queueRevision
        self.queue = queue
        self.queueIndex = queueIndex
        self.position = position
        self.intent = intent
        self.replayGainMode = replayGainMode
        self.replayGainPreampDB = replayGainPreampDB
        self.masterVolume = masterVolume
        self.eqEnabled = eqEnabled
        self.eqBands = eqBands
        self.route = route
        self.sourceFormat = sourceFormat
        self.outputFormat = outputFormat
        self.timestamp = timestamp
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(version, forKey: .version)
        try container.encode(trackID, forKey: .trackID)
        try container.encode(queueRevision, forKey: .queueRevision)
        try container.encode(queue, forKey: .queue)
        try container.encode(queueIndex, forKey: .queueIndex)
        try container.encode(position, forKey: .position)
        try container.encode(intent, forKey: .intent)
        try container.encode(replayGainMode, forKey: .replayGainMode)
        try container.encode(replayGainPreampDB, forKey: .replayGainPreampDB)
        try container.encode(masterVolume, forKey: .masterVolume)
        try container.encode(eqEnabled, forKey: .eqEnabled)
        try container.encode(eqBands, forKey: .eqBands)
        try container.encode(route, forKey: .route)
        try container.encode(sourceFormat, forKey: .sourceFormat)
        try container.encode(outputFormat, forKey: .outputFormat)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

struct PlaybackFailure: Error, Codable, Equatable {
    let code: String
    let message: String
    let recoverable: Bool
    let trackID: String?
}

final class StateVersionClock {
    private let lock = NSLock()
    private var value: UInt64

    init(seed: UInt64 = 0) {
        value = seed
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        precondition(value < UInt64.max, "State version exhausted")
        value += 1
        return value
    }
}
