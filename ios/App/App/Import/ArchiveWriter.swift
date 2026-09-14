import Foundation

struct AeonArchiveTrack: Codable, Equatable {
    let id: String
    let albumID: String
    let sequence: Int
    let discNumber: Int?
    let trackNumber: Int?
    let title: String
    let artist: String
    let duration: TimeInterval?
    let byteCount: Int64
    let mediaReference: MediaReference
    let importedAt: TimeInterval
    let audioPath: String?
}

struct AeonArchiveAlbum: Codable, Equatable {
    let id: String
    let sequence: Int64
    let title: String
    let artist: String
    let year: String
    let genre: String
    let importedAt: TimeInterval
    let updatedAt: TimeInterval
    let artworkPath: String?
    let tracks: [AeonArchiveTrack]
}

struct AeonArchivePlaylist: Codable, Equatable {
    let id: String
    let name: String
    let createdAt: TimeInterval
    let updatedAt: TimeInterval
    let trackIDs: [String]
}

struct AeonArchiveListening: Codable, Equatable {
    let trackID: String
    let playCount: Int64
    let completedCount: Int64
    let lastPosition: TimeInterval
    let lastPlayedAt: TimeInterval?
}

struct AeonArchiveSetting: Codable, Equatable {
    let key: String
    let value: Data
    let updatedAt: TimeInterval
}

struct AeonArchiveSkyRecord: Codable, Equatable {
    let id: String
    let kind: SkyRecordKind
    let sequence: Int64
    let payload: Data
    let updatedAt: TimeInterval
}

struct AeonArchiveCatalog: Codable, Equatable {
    static let version = 3

    let v: Int
    let compatibilityVersion: Int
    let exportedAt: TimeInterval
    let albums: [AeonArchiveAlbum]
    let playlists: [AeonArchivePlaylist]
    let listening: [AeonArchiveListening]
    let settings: [AeonArchiveSetting]
    let queueCheckpoint: PlaybackSnapshot?
    let skySeed: UInt32?
    let skyRecords: [AeonArchiveSkyRecord]
}

struct ArchiveExportProgress: Equatable {
    let completedEntries: Int
    let completedBytes: UInt64
    let currentPath: String
}

enum ArchiveWriterError: Error, Equatable {
    case unsafePath(String)
    case missingSource(String)
    case sourceTooLarge
    case archiveTooLarge
}

final class ArchiveWriter {
    static let catalogFilename = "isolation-backup.json"
    static let catalogOnlyFilename = "isolation-catalog.json"

    private let repository: CatalogRepository
    private let artworkStore: ArtworkStore
    private let mediaStore: MediaStore
    private let temporaryRoot: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    init(
        repository: CatalogRepository,
        artworkStore: ArtworkStore,
        mediaStore: MediaStore,
        temporaryRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.artworkStore = artworkStore
        self.mediaStore = mediaStore
        self.temporaryRoot = temporaryRoot
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func writeCatalogue(
        to destination: URL,
        playbackSnapshot: PlaybackSnapshot?,
        exportedAt: Date = Date()
    ) throws {
        try writeCatalogJSON(
            to: destination,
            includeMedia: false,
            playbackSnapshot: playbackSnapshot,
            exportedAt: exportedAt
        )
    }

    func writeFullBackup(
        to destination: URL,
        playbackSnapshot: PlaybackSnapshot?,
        exportedAt: Date = Date(),
        progress: (ArchiveExportProgress) -> Void = { _ in }
    ) throws {
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let operationRoot = temporaryRoot.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial", isDirectory: false)
        try fileManager.createDirectory(at: operationRoot, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: partial)
        defer {
            try? fileManager.removeItem(at: operationRoot)
            if fileManager.fileExists(atPath: partial.path) { try? fileManager.removeItem(at: partial) }
        }

        let catalogURL = operationRoot.appendingPathComponent(Self.catalogFilename, isDirectory: false)
        try writeCatalogJSON(
            to: catalogURL,
            includeMedia: true,
            playbackSnapshot: playbackSnapshot,
            exportedAt: exportedAt
        )
        let zip = try Zip64StoreWriter(url: partial, fileManager: fileManager)
        try zip.append(path: Self.catalogFilename, sourceURL: catalogURL, progress: progress)
        try forEachAlbum { album in
            if let key = album.artworkKey {
                let source = try artworkStore.url(forKey: key)
                if fileManager.fileExists(atPath: source.path) {
                    try zip.append(path: artworkArchivePath(key: key), sourceURL: source, progress: progress)
                }
            }
            try forEachTrack(albumID: album.id) { track in
                switch track.mediaReference {
                case .unavailable, .legacyBlob:
                    return
                case .native, .documents, .externalBookmark:
                    break
                }
                guard let path = try audioArchivePath(for: track), let source = try mediaURL(for: track) else {
                    throw ArchiveWriterError.missingSource(track.id)
                }
                defer { mediaStore.release(source) }
                guard fileManager.fileExists(atPath: source.path) else {
                    throw ArchiveWriterError.missingSource(track.id)
                }
                try zip.append(path: path, sourceURL: source, progress: progress)
            }
        }
        try zip.finish()
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fileManager.moveItem(at: partial, to: destination)
        }
    }

    func writeActivityLog(to destination: URL, exportedAt: Date = Date()) throws {
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial", isDirectory: false)
        try? fileManager.removeItem(at: partial)
        defer { try? fileManager.removeItem(at: partial) }
        fileManager.createFile(atPath: partial.path, contents: nil)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        try output.write(contentsOf: Data("{\"exportedAt\":\(exportedAt.timeIntervalSince1970),\"listening\":[".utf8))
        var first = true
        try forEachListening { listening in
            if !first { try output.write(contentsOf: Data(",".utf8)) }
            first = false
            try output.write(contentsOf: try encoder.encode(archiveListening(listening)))
        }
        try output.write(contentsOf: Data("]}".utf8))
        try output.synchronize()
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fileManager.moveItem(at: partial, to: destination)
        }
    }

    private func writeCatalogJSON(
        to destination: URL,
        includeMedia: Bool,
        playbackSnapshot: PlaybackSnapshot?,
        exportedAt: Date
    ) throws {
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial", isDirectory: false)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: partial)
        defer { try? fileManager.removeItem(at: partial) }
        fileManager.createFile(atPath: partial.path, contents: nil)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }

        func write(_ string: String) throws { try output.write(contentsOf: Data(string.utf8)) }
        func writeValue<T: Encodable>(_ value: T) throws { try output.write(contentsOf: encoder.encode(value)) }
        try write("{\"v\":\(AeonArchiveCatalog.version),\"compatibilityVersion\":2,\"exportedAt\":\(exportedAt.timeIntervalSince1970),\"albums\":[")
        var first = true
        try forEachAlbum { album in
            if !first { try write(",") }
            first = false
            try write("{\"id\":")
            try writeValue(album.id)
            try write(",\"sequence\":\(album.sequence),\"title\":")
            try writeValue(album.title)
            try write(",\"artist\":")
            try writeValue(album.artist)
            try write(",\"year\":")
            try writeValue(album.year)
            try write(",\"genre\":")
            try writeValue(album.genre)
            try write(",\"importedAt\":\(album.importedAt.timeIntervalSince1970),\"updatedAt\":\(album.updatedAt.timeIntervalSince1970),\"artworkPath\":")
            let artworkPath: String? = includeMedia && album.artworkKey.flatMap({ try? artworkStore.url(forKey: $0) }).map({ fileManager.fileExists(atPath: $0.path) }) == true
                ? album.artworkKey.map(artworkArchivePath)
                : nil
            try writeValue(artworkPath)
            try write(",\"tracks\":[")
            var firstTrack = true
            try forEachTrack(albumID: album.id) { track in
                if !firstTrack { try write(",") }
                firstTrack = false
                try writeValue(try archiveTrack(track, includeMedia: includeMedia))
            }
            try write("]}")
        }

        try write("],\"playlists\":[")
        first = true
        try forEachPlaylist { playlist in
            if !first { try write(",") }
            first = false
            try write("{\"id\":")
            try writeValue(playlist.id)
            try write(",\"name\":")
            try writeValue(playlist.name)
            try write(",\"createdAt\":\(playlist.createdAt.timeIntervalSince1970),\"updatedAt\":\(playlist.updatedAt.timeIntervalSince1970),\"trackIDs\":[")
            var offset = 0
            var firstItem = true
            while true {
                let page = try repository.playlistItems(playlistID: playlist.id, offset: offset)
                for item in page {
                    if !firstItem { try write(",") }
                    firstItem = false
                    try writeValue(item.trackID)
                }
                guard page.count == CatalogDatabase.maximumPageSize else { break }
                offset += page.count
            }
            try write("]}")
        }

        try write("],\"listening\":[")
        first = true
        try forEachListening { listening in
            if !first { try write(",") }
            first = false
            try writeValue(archiveListening(listening))
        }

        try write("],\"settings\":[")
        first = true
        try forEachSetting { setting in
            if !first { try write(",") }
            first = false
            try writeValue(AeonArchiveSetting(
                key: setting.key,
                value: setting.value,
                updatedAt: setting.updatedAt.timeIntervalSince1970
            ))
        }

        try write("],\"queueCheckpoint\":")
        try writeValue(playbackSnapshot)
        let skySeed = try repository.setting(UInt32.self, forKey: "sky.seed")
        try write(",\"skySeed\":")
        try writeValue(skySeed)
        try write(",\"skyRecords\":[")
        first = true
        for kind in SkyRecordKind.allCases {
            var offset = 0
            while true {
                let page = try repository.skyRecords(kind: kind, offset: offset)
                for record in page {
                    if !first { try write(",") }
                    first = false
                    try writeValue(AeonArchiveSkyRecord(
                        id: record.id,
                        kind: record.kind,
                        sequence: record.sequence,
                        payload: record.payload,
                        updatedAt: record.updatedAt.timeIntervalSince1970
                    ))
                }
                guard page.count == CatalogDatabase.maximumPageSize else { break }
                offset += page.count
            }
        }
        try write("]}")
        try output.synchronize()
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fileManager.moveItem(at: partial, to: destination)
        }
    }

    private func archiveTrack(_ track: CatalogTrack, includeMedia: Bool) throws -> AeonArchiveTrack {
        AeonArchiveTrack(
            id: track.id,
            albumID: track.albumID,
            sequence: track.sequence,
            discNumber: track.discNumber,
            trackNumber: track.trackNumber,
            title: track.title,
            artist: track.artist,
            duration: track.duration,
            byteCount: track.byteCount,
            mediaReference: track.mediaReference,
            importedAt: track.importedAt.timeIntervalSince1970,
            audioPath: includeMedia ? try audioArchivePath(for: track) : nil
        )
    }

    private func archiveListening(_ value: CatalogListeningState) -> AeonArchiveListening {
        AeonArchiveListening(
            trackID: value.trackID,
            playCount: value.playCount,
            completedCount: value.completedCount,
            lastPosition: value.lastPosition,
            lastPlayedAt: value.lastPlayedAt?.timeIntervalSince1970
        )
    }

    private func audioArchivePath(for track: CatalogTrack) throws -> String? {
        switch track.mediaReference {
        case .unavailable, .legacyBlob: return nil
        case .native, .documents, .externalBookmark:
            guard let source = try mediaURL(for: track) else { return nil }
            defer { mediaStore.release(source) }
            let ext = source.pathExtension.lowercased()
            guard !ext.isEmpty, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw ArchiveWriterError.unsafePath(track.id)
            }
            return "audio/\(Self.archiveComponent(track.id)).\(ext)"
        }
    }

    private func artworkArchivePath(key: String) -> String { "artwork/\(key)" }

    private func mediaURL(for track: CatalogTrack) throws -> URL? {
        switch track.mediaReference {
        case .unavailable, .legacyBlob: return nil
        case .native, .documents, .externalBookmark: return try mediaStore.resolve(track.mediaReference)
        }
    }

    private static func archiveComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func forEachAlbum(_ body: (CatalogAlbum) throws -> Void) throws {
        var offset = 0
        while true {
            let page = try repository.albumPage(offset: offset, limit: CatalogDatabase.maximumPageSize, sort: .recentlyAdded)
            for summary in page {
                if let album = try repository.album(id: summary.id) { try body(album) }
            }
            guard page.count == CatalogDatabase.maximumPageSize else { break }
            offset += page.count
        }
    }

    private func forEachTrack(albumID: String, _ body: (CatalogTrack) throws -> Void) throws {
        var offset = 0
        while true {
            let page = try repository.tracks(albumID: albumID, offset: offset)
            for track in page { try body(track) }
            guard page.count == CatalogDatabase.maximumPageSize else { break }
            offset += page.count
        }
    }

    private func forEachPlaylist(_ body: (CatalogPlaylist) throws -> Void) throws {
        var offset = 0
        while true {
            let page = try repository.playlists(offset: offset)
            for playlist in page { try body(playlist) }
            guard page.count == CatalogDatabase.maximumPageSize else { break }
            offset += page.count
        }
    }

    private func forEachListening(_ body: (CatalogListeningState) throws -> Void) throws {
        var offset = 0
        while true {
            let page = try repository.listeningStates(offset: offset)
            for value in page { try body(value) }
            guard page.count == CatalogDatabase.maximumPageSize else { break }
            offset += page.count
        }
    }

    private func forEachSetting(_ body: (CatalogSettingRecord) throws -> Void) throws {
        var offset = 0
        while true {
            let page = try repository.settingRecords(offset: offset)
            for value in page { try body(value) }
            guard page.count == CatalogDatabase.maximumPageSize else { break }
            offset += page.count
        }
    }
}

private final class Zip64StoreWriter {
    private struct DirectoryEntry {
        let path: String
        let crc32: UInt32
        let size: UInt64
        let offset: UInt64
    }

    private let output: FileHandle
    private let fileManager: FileManager
    private var offset: UInt64 = 0
    private var entries: [DirectoryEntry] = []
    private var finished = false

    init(url: URL, fileManager: FileManager) throws {
        self.fileManager = fileManager
        fileManager.createFile(atPath: url.path, contents: nil)
        output = try FileHandle(forWritingTo: url)
    }

    deinit { try? output.close() }

    func append(path: String, sourceURL: URL, progress: (ArchiveExportProgress) -> Void) throws {
        guard ArchivePath.isSafe(path), entries.count < 100_000 else { throw ArchiveWriterError.unsafePath(path) }
        let sizeValue = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let sizeValue, sizeValue >= 0 else { throw ArchiveWriterError.missingSource(path) }
        let size = UInt64(sizeValue)
        let name = Data(path.utf8)
        guard name.count <= Int(UInt16.max) else { throw ArchiveWriterError.unsafePath(path) }
        let localOffset = offset
        var local = Data()
        local.appendLE(UInt32(0x04034b50))
        local.appendLE(UInt16(45))
        local.appendLE(UInt16(0x0808))
        local.appendLE(UInt16(0))
        local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
        local.appendLE(UInt32(0))
        local.appendLE(UInt32.max); local.appendLE(UInt32.max)
        local.appendLE(UInt16(name.count)); local.appendLE(UInt16(20))
        local.append(name)
        local.appendLE(UInt16(0x0001)); local.appendLE(UInt16(16))
        local.appendLE(size); local.appendLE(size)
        try write(local)

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        var crc = CRC32.initial
        var copied: UInt64 = 0
        while copied < size {
            let amount = Int(min(UInt64(512 * 1_024), size - copied))
            guard let chunk = try input.read(upToCount: amount), !chunk.isEmpty else {
                throw ArchiveWriterError.missingSource(path)
            }
            crc = CRC32.update(crc, with: chunk)
            try write(chunk)
            copied += UInt64(chunk.count)
            progress(ArchiveExportProgress(completedEntries: entries.count, completedBytes: copied, currentPath: path))
        }
        var descriptor = Data()
        descriptor.appendLE(UInt32(0x08074b50))
        descriptor.appendLE(CRC32.finish(crc))
        descriptor.appendLE(size); descriptor.appendLE(size)
        try write(descriptor)
        entries.append(DirectoryEntry(path: path, crc32: CRC32.finish(crc), size: size, offset: localOffset))
        progress(ArchiveExportProgress(completedEntries: entries.count, completedBytes: size, currentPath: path))
    }

    func finish() throws {
        guard !finished else { return }
        let directoryOffset = offset
        for entry in entries {
            let name = Data(entry.path.utf8)
            var central = Data()
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(0x031E)); central.appendLE(UInt16(45))
            central.appendLE(UInt16(0x0808)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(entry.crc32)
            central.appendLE(UInt32.max); central.appendLE(UInt32.max)
            central.appendLE(UInt16(name.count)); central.appendLE(UInt16(28))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt32(0)); central.appendLE(UInt32.max)
            central.append(name)
            central.appendLE(UInt16(0x0001)); central.appendLE(UInt16(24))
            central.appendLE(entry.size); central.appendLE(entry.size); central.appendLE(entry.offset)
            try write(central)
        }
        let directorySize = offset - directoryOffset
        let zip64Offset = offset
        var end64 = Data()
        end64.appendLE(UInt32(0x06064b50)); end64.appendLE(UInt64(44))
        end64.appendLE(UInt16(0x031E)); end64.appendLE(UInt16(45))
        end64.appendLE(UInt32(0)); end64.appendLE(UInt32(0))
        end64.appendLE(UInt64(entries.count)); end64.appendLE(UInt64(entries.count))
        end64.appendLE(directorySize); end64.appendLE(directoryOffset)
        try write(end64)
        var locator = Data()
        locator.appendLE(UInt32(0x07064b50)); locator.appendLE(UInt32(0))
        locator.appendLE(zip64Offset); locator.appendLE(UInt32(1))
        try write(locator)
        var end = Data()
        end.appendLE(UInt32(0x06054b50)); end.appendLE(UInt16(0)); end.appendLE(UInt16(0))
        end.appendLE(UInt16.max); end.appendLE(UInt16.max)
        end.appendLE(UInt32.max); end.appendLE(UInt32.max); end.appendLE(UInt16(0))
        try write(end)
        try output.synchronize()
        try output.close()
        finished = true
    }

    private func write(_ data: Data) throws {
        try output.write(contentsOf: data)
        let (next, overflow) = offset.addingReportingOverflow(UInt64(data.count))
        guard !overflow else { throw ArchiveWriterError.archiveTooLarge }
        offset = next
    }
}

enum ArchivePath {
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

enum CRC32 {
    static let initial = UInt32.max
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) == 1 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        data.reduce(crc) { value, byte in table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
    }

    static func finish(_ crc: UInt32) -> UInt32 { ~crc }
}

extension Data {
    mutating func appendLE<Value: FixedWidthInteger>(_ value: Value) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
