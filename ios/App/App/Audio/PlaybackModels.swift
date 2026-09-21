import Foundation

enum PlaybackIntent: String, Codable {
    case playing
    case paused
}

enum ReplayGainMode: String, Codable, CaseIterable, Identifiable {
    // Declaration order is the order the Settings control offers them.
    case off
    case track
    case album

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "OFF"
        case .track: return "TRACK"
        case .album: return "ALBUM"
        }
    }

    var spokenLabel: String {
        switch self {
        case .off: return "Off"
        case .track: return "Match track loudness"
        case .album: return "Match album loudness"
        }
    }
}

enum RepeatMode: String, Codable, CaseIterable {
    case off
    case all
    case one
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
    case documents(relativePath: String)
    case externalBookmark(Data)
    case legacyBlob(trackID: String)
    case unavailable(trackID: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case relativePath
        case bookmark
        case trackID
    }

    private enum Kind: String, Codable {
        case native
        case documents
        case externalBookmark
        case legacyBlob
        case unavailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .native:
            self = .native(relativePath: try container.decode(String.self, forKey: .relativePath))
        case .documents:
            self = .documents(relativePath: try container.decode(String.self, forKey: .relativePath))
        case .externalBookmark:
            self = .externalBookmark(try container.decode(Data.self, forKey: .bookmark))
        case .legacyBlob:
            self = .legacyBlob(trackID: try container.decode(String.self, forKey: .trackID))
        case .unavailable:
            self = .unavailable(trackID: try container.decode(String.self, forKey: .trackID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .native(let relativePath):
            try container.encode(Kind.native, forKey: .type)
            try container.encode(relativePath, forKey: .relativePath)
        case .documents(let relativePath):
            try container.encode(Kind.documents, forKey: .type)
            try container.encode(relativePath, forKey: .relativePath)
        case .externalBookmark(let bookmark):
            try container.encode(Kind.externalBookmark, forKey: .type)
            try container.encode(bookmark, forKey: .bookmark)
        case .legacyBlob(let trackID):
            try container.encode(Kind.legacyBlob, forKey: .type)
            try container.encode(trackID, forKey: .trackID)
        case .unavailable(let trackID):
            try container.encode(Kind.unavailable, forKey: .type)
            try container.encode(trackID, forKey: .trackID)
        }
    }
}

struct QueueItem: Codable, Equatable, Identifiable {
    let id: String
    let trackID: String
    let albumID: String
    let mediaRef: MediaReference

    init(trackID: String, albumID: String, mediaRef: MediaReference, id: String = UUID().uuidString) {
        self.id = id
        self.trackID = trackID
        self.albumID = albumID
        self.mediaRef = mediaRef
    }

    private enum CodingKeys: String, CodingKey { case id, trackID, albumID, mediaRef }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Legacy snapshots had no occurrence identity. Assign once on load; the
        // coordinator's next normal snapshot write persists it without a rescan.
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        trackID = try values.decode(String.self, forKey: .trackID)
        albumID = try values.decode(String.self, forKey: .albumID)
        mediaRef = try values.decode(MediaReference.self, forKey: .mediaRef)
    }
}

struct SourceFormatDescriptor: Codable, Equatable {
    let codec: String?
    let container: String?
    let sampleRate: Double?
    let channelCount: Int?
    let bitDepth: Int?
    let duration: Double?
    let replayGain: ReplayGainValues?

    init(
        codec: String?,
        container: String?,
        sampleRate: Double?,
        channelCount: Int?,
        bitDepth: Int?,
        duration: Double?,
        replayGain: ReplayGainValues? = nil
    ) {
        self.codec = codec
        self.container = container
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.duration = duration
        self.replayGain = replayGain
    }
}

struct RouteDescriptor: Codable, Equatable {
    let kind: AudioRouteKind
    let name: String
    var persistentID: String? = nil
    let sampleRate: Double?
    let channelCount: Int?
}

struct OutputFormatDescriptor: Codable, Equatable {
    let sampleRate: Double
    let channelCount: Int
    let route: RouteDescriptor
    let processingSampleRate: Double?
    var effectivePreampDB: Double?
    var unavailableFilters: Int?
    var dspLatency: Double?
    var overloadCount: UInt64?

    init(sampleRate: Double, channelCount: Int, route: RouteDescriptor, processingSampleRate: Double? = nil, effectivePreampDB: Double? = nil, unavailableFilters: Int? = nil, dspLatency: Double? = nil, overloadCount: UInt64? = nil) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.route = route
        self.processingSampleRate = processingSampleRate
        self.effectivePreampDB = effectivePreampDB; self.unavailableFilters = unavailableFilters
        self.dspLatency = dspLatency; self.overloadCount = overloadCount
    }
}

enum EQFilterType: String, Codable, CaseIterable, Identifiable {
    case bell, lowShelf, highShelf, highPass, lowPass
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bell: return "Bell"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .highPass: return "Low cut · 12 dB/oct"
        case .lowPass: return "High cut · 12 dB/oct"
        }
    }
}

struct EQBand: Codable, Equatable, Identifiable {
    var frequency: Double
    var q: Double
    var gainDB: Double
    var id: String
    var enabled: Bool
    var type: EQFilterType
    var version: Int

    init(frequency: Double, q: Double, gainDB: Double, id: String? = nil,
         enabled: Bool = true, type: EQFilterType = .bell, version: Int = 1) {
        self.frequency = frequency; self.q = q; self.gainDB = gainDB
        self.id = id ?? "band-\(frequency)"; self.enabled = enabled; self.type = type; self.version = version
    }
    private enum CodingKeys: String, CodingKey { case frequency, q, gainDB, id, enabled, type, version }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(Double.self, forKey: .frequency)
        q = try c.decode(Double.self, forKey: .q)
        gainDB = try c.decode(Double.self, forKey: .gainDB)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "band-\(frequency)"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        type = try c.decodeIfPresent(EQFilterType.self, forKey: .type) ?? .bell
        // Keep historical native octave-width semantics until an explicit edit/reset.
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
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
    let repeatMode: RepeatMode
    var dsp: DSPSettings = .init()
    let route: RouteDescriptor?
    let sourceFormat: SourceFormatDescriptor?
    let outputFormat: OutputFormatDescriptor?
    let timestamp: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, version, trackID, queueRevision, queue, queueIndex, position, intent
        case replayGainMode, replayGainPreampDB, masterVolume, eqEnabled, eqBands, repeatMode
        case route, sourceFormat, outputFormat, timestamp, dsp
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
        repeatMode: RepeatMode = .off,
        dsp: DSPSettings = .init(),
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
        self.repeatMode = repeatMode
        self.dsp = dsp
        self.route = route
        self.sourceFormat = sourceFormat
        self.outputFormat = outputFormat
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        version = try container.decode(UInt64.self, forKey: .version)
        trackID = try container.decodeIfPresent(String.self, forKey: .trackID)
        queueRevision = try container.decode(UInt64.self, forKey: .queueRevision)
        queue = try container.decode([QueueItem].self, forKey: .queue)
        queueIndex = try container.decodeIfPresent(Int.self, forKey: .queueIndex)
        position = try container.decode(Double.self, forKey: .position)
        intent = try container.decode(PlaybackIntent.self, forKey: .intent)
        replayGainMode = try container.decode(ReplayGainMode.self, forKey: .replayGainMode)
        replayGainPreampDB = try container.decode(Double.self, forKey: .replayGainPreampDB)
        masterVolume = try container.decode(Double.self, forKey: .masterVolume)
        eqEnabled = try container.decode(Bool.self, forKey: .eqEnabled)
        eqBands = try container.decode([EQBand].self, forKey: .eqBands)
        repeatMode = try container.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
        dsp = try container.decodeIfPresent(DSPSettings.self, forKey: .dsp) ?? .init()
        route = try container.decodeIfPresent(RouteDescriptor.self, forKey: .route)
        sourceFormat = try container.decodeIfPresent(SourceFormatDescriptor.self, forKey: .sourceFormat)
        outputFormat = try container.decodeIfPresent(OutputFormatDescriptor.self, forKey: .outputFormat)
        timestamp = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .timestamp))
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
        try container.encode(repeatMode, forKey: .repeatMode)
        try container.encode(dsp, forKey: .dsp)
        try container.encode(route, forKey: .route)
        try container.encode(sourceFormat, forKey: .sourceFormat)
        try container.encode(outputFormat, forKey: .outputFormat)
        try container.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
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

    func next() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard value < UInt64.max else { return nil }
        value += 1
        return value
    }
}
