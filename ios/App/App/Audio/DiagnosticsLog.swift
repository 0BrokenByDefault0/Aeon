import Foundation

struct DiagnosticEntry: Codable, Equatable {
    let timestamp: Date
    let eventCode: String
    let trackID: String?
    let sourceFormat: SourceFormatDescriptor?
    let outputFormat: OutputFormatDescriptor?
    let route: RouteDescriptor?
    let recoverable: Bool?
    let fileExtension: String?

    fileprivate init(
        timestamp: Date,
        eventCode: String,
        trackID: String?,
        sourceFormat: SourceFormatDescriptor?,
        outputFormat: OutputFormatDescriptor?,
        route: RouteDescriptor?,
        recoverable: Bool?,
        fileExtension: String?
    ) {
        self.timestamp = timestamp
        self.eventCode = eventCode
        self.trackID = trackID
        self.sourceFormat = sourceFormat
        self.outputFormat = outputFormat
        self.route = route
        self.recoverable = recoverable
        self.fileExtension = fileExtension
    }
}

final class DiagnosticsLog {
    private let url: URL
    private let maxEntryCount: Int
    private let maxByteCount: Int
    private let fileManager: FileManager
    private let lock = NSLock()
    private var ring: [DiagnosticEntry]

    init(
        url: URL,
        maxEntryCount: Int = 200,
        maxByteCount: Int = 256 * 1_024,
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.maxEntryCount = max(0, maxEntryCount)
        self.maxByteCount = max(0, maxByteCount)
        self.fileManager = fileManager
        ring = Self.readEntries(from: url)
        ring = Array(ring.suffix(self.maxEntryCount))
        Self.trimToByteLimit(&ring, maxByteCount: self.maxByteCount)
        if fileManager.fileExists(atPath: url.path) {
            try? Self.persist(ring, to: url, fileManager: fileManager)
        }
    }

    func record(
        eventCode: String,
        trackID: String? = nil,
        sourceFormat: SourceFormatDescriptor? = nil,
        outputFormat: OutputFormatDescriptor? = nil,
        route: RouteDescriptor? = nil,
        recoverable: Bool? = nil,
        filePath: String? = nil,
        timestamp: Date = Date()
    ) throws {
        let entry = DiagnosticEntry(
            timestamp: timestamp,
            eventCode: Self.sanitize(eventCode),
            trackID: trackID.map(Self.sanitize),
            sourceFormat: sourceFormat.map(Self.sanitize),
            outputFormat: outputFormat.map(Self.sanitize),
            route: route.map(Self.sanitize),
            recoverable: recoverable,
            fileExtension: Self.safeExtension(from: filePath)
        )

        lock.lock()
        defer { lock.unlock() }
        var candidate = ring
        candidate.append(entry)
        candidate = Array(candidate.suffix(maxEntryCount))
        Self.trimToByteLimit(&candidate, maxByteCount: maxByteCount)
        try Self.persist(candidate, to: url, fileManager: fileManager)
        ring = candidate
    }

    func entries() -> [DiagnosticEntry] {
        lock.lock()
        defer { lock.unlock() }
        return ring
    }

    private static func readEntries(from url: URL) -> [DiagnosticEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap {
            try? JSONDecoder().decode(DiagnosticEntry.self, from: Data($0))
        }.map(sanitize)
    }

    private static func encodedJSONLines(_ entries: [DiagnosticEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        return data
    }

    private static func persist(_ entries: [DiagnosticEntry], to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try encodedJSONLines(entries).write(to: url, options: .atomic)
    }

    private static func trimToByteLimit(_ entries: inout [DiagnosticEntry], maxByteCount: Int) {
        while !entries.isEmpty,
              ((try? encodedJSONLines(entries).count) ?? (maxByteCount + 1)) > maxByteCount {
            entries.removeFirst()
        }
    }

    private static func safeExtension(from path: String?) -> String? {
        guard let path = path else { return nil }
        let value = (path as NSString).pathExtension.lowercased()
        guard !value.isEmpty, value.range(of: #"^[a-z0-9]{1,16}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private static func sanitize(_ value: String) -> String {
        if value.contains("/") || value.contains("\\") {
            return "[redacted-path]"
        }
        return value
    }

    private static func sanitize(_ value: SourceFormatDescriptor) -> SourceFormatDescriptor {
        SourceFormatDescriptor(
            codec: canonicalFormat(value.codec, allowed: ["aac", "aiff", "alac", "flac", "mp3", "ogg", "opus", "pcm", "wav"]),
            container: canonicalFormat(value.container, allowed: ["aiff", "caf", "flac", "m4a", "mp3", "ogg", "wav"]),
            sampleRate: value.sampleRate,
            channelCount: value.channelCount,
            bitDepth: value.bitDepth,
            duration: value.duration
        )
    }

    private static func sanitize(_ value: RouteDescriptor) -> RouteDescriptor {
        RouteDescriptor(
            kind: value.kind,
            name: value.kind.rawValue,
            sampleRate: value.sampleRate,
            channelCount: value.channelCount
        )
    }

    private static func canonicalFormat(_ value: String?, allowed: Set<String>) -> String? {
        guard let token = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              allowed.contains(token) else {
            return nil
        }
        return token
    }

    private static func sanitize(_ value: OutputFormatDescriptor) -> OutputFormatDescriptor {
        OutputFormatDescriptor(
            sampleRate: value.sampleRate,
            channelCount: value.channelCount,
            route: sanitize(value.route)
        )
    }

    private static func sanitize(_ value: DiagnosticEntry) -> DiagnosticEntry {
        DiagnosticEntry(
            timestamp: value.timestamp,
            eventCode: sanitize(value.eventCode),
            trackID: value.trackID.map(sanitize),
            sourceFormat: value.sourceFormat.map(sanitize),
            outputFormat: value.outputFormat.map(sanitize),
            route: value.route.map(sanitize),
            recoverable: value.recoverable,
            fileExtension: safeExtension(from: value.fileExtension.map { "file.\($0)" })
        )
    }
}
