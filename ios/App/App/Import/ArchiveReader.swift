import Compression
import Foundation

struct ArchiveReadLimits: Equatable {
    var maximumEntryCount = 100_000
    var maximumCentralDirectoryBytes: UInt64 = 64 * 1_024 * 1_024
    var maximumEntryBytes: UInt64 = 1_099_511_627_776
    var maximumTotalBytes: UInt64 = 4_398_046_511_104
}

struct ArchiveEntry: Equatable {
    let path: String
    let method: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let size: UInt64
    let localHeaderOffset: UInt64
}

enum ArchiveReaderError: Error, Equatable {
    case notZIP
    case corruptDirectory
    case unsupportedCompression(String)
    case encrypted(String)
    case unsafePath(String)
    case duplicatePath(String)
    case limitExceeded(String)
    case truncated(String)
    case checksumFailed(String)
    case invalidCatalog(String)
    case unsupportedVersion(Int)
}

final class ArchiveReader {
    let url: URL
    let entries: [ArchiveEntry]

    private let limits: ArchiveReadLimits
    private let fileManager: FileManager

    init(url: URL, limits: ArchiveReadLimits = ArchiveReadLimits(), fileManager: FileManager = .default) throws {
        self.url = url
        self.limits = limits
        self.fileManager = fileManager
        entries = try Self.readDirectory(url: url, limits: limits)
    }

    @discardableResult
    func extractAll(to root: URL, progress: (ArchiveExportProgress) -> Void = { _ in }) throws -> [String: URL] {
        let incoming = root.appendingPathComponent(".incoming", isDirectory: true)
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
        var result: [String: URL] = [:]
        do {
            for (index, entry) in entries.enumerated() {
                let destination = root.appendingPathComponent(entry.path, isDirectory: false)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let partial = incoming.appendingPathComponent("\(index)-\(UUID().uuidString).partial", isDirectory: false)
                try extract(entry, to: partial) { copied in
                    progress(ArchiveExportProgress(completedEntries: index, completedBytes: copied, currentPath: entry.path))
                }
                if fileManager.fileExists(atPath: destination.path) { throw ArchiveReaderError.duplicatePath(entry.path) }
                try fileManager.moveItem(at: partial, to: destination)
                result[entry.path] = destination
                progress(ArchiveExportProgress(completedEntries: index + 1, completedBytes: entry.size, currentPath: entry.path))
            }
            try? fileManager.removeItem(at: incoming)
            return result
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private func extract(_ entry: ArchiveEntry, to destination: URL, progress: (UInt64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: entry.localHeaderOffset)
        guard let header = try input.read(upToCount: 30), header.count == 30,
              header.le32(0) == 0x04034b50 else { throw ArchiveReaderError.truncated(entry.path) }
        let flags = header.le16(6)
        guard flags & 0x0001 == 0 else { throw ArchiveReaderError.encrypted(entry.path) }
        guard header.le16(8) == entry.method else { throw ArchiveReaderError.corruptDirectory }
        let nameLength = UInt64(header.le16(26))
        let extraLength = UInt64(header.le16(28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        try input.seek(toOffset: dataOffset)
        fileManager.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var crc = CRC32.initial
        var written: UInt64 = 0
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw ArchiveReaderError.corruptDirectory }
            var remaining = entry.compressedSize
            while remaining > 0 {
                let amount = Int(min(UInt64(512 * 1_024), remaining))
                guard let chunk = try input.read(upToCount: amount), !chunk.isEmpty else {
                    throw ArchiveReaderError.truncated(entry.path)
                }
                try output.write(contentsOf: chunk)
                crc = CRC32.update(crc, with: chunk)
                written += UInt64(chunk.count)
                remaining -= UInt64(chunk.count)
                progress(written)
            }
        case 8:
            try inflate(input: input, compressedBytes: entry.compressedSize, output: output) { chunk in
                crc = CRC32.update(crc, with: chunk)
                written += UInt64(chunk.count)
                progress(written)
            }
        default:
            throw ArchiveReaderError.unsupportedCompression(entry.path)
        }
        try output.synchronize()
        guard written == entry.size else { throw ArchiveReaderError.truncated(entry.path) }
        guard CRC32.finish(crc) == entry.crc32 else { throw ArchiveReaderError.checksumFailed(entry.path) }
    }

    private func inflate(
        input: FileHandle,
        compressedBytes: UInt64,
        output: FileHandle,
        consume: (Data) throws -> Void
    ) throws {
        let seed = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { seed.deallocate() }
        var stream = compression_stream(
            dst_ptr: seed,
            dst_size: 0,
            src_ptr: UnsafePointer(seed),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw ArchiveReaderError.corruptDirectory
        }
        defer { compression_stream_destroy(&stream) }
        var remaining = compressedBytes
        var reachedEnd = false
        let destinationSize = 512 * 1_024
        var destination = [UInt8](repeating: 0, count: destinationSize)
        while remaining > 0 && !reachedEnd {
            let amount = Int(min(UInt64(256 * 1_024), remaining))
            guard let source = try input.read(upToCount: amount), !source.isEmpty else {
                throw ArchiveReaderError.corruptDirectory
            }
            remaining -= UInt64(source.count)
            try source.withUnsafeBytes { rawSource in
                guard let sourceBase = rawSource.bindMemory(to: UInt8.self).baseAddress else { return }
                stream.src_ptr = sourceBase
                stream.src_size = source.count
                repeat {
                    let status: compression_status = destination.withUnsafeMutableBytes { rawDestination in
                        stream.dst_ptr = rawDestination.bindMemory(to: UInt8.self).baseAddress!
                        stream.dst_size = destinationSize
                        return compression_stream_process(&stream, remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    }
                    let produced = destinationSize - stream.dst_size
                    if produced > 0 {
                        let chunk = Data(destination[0..<produced])
                        try output.write(contentsOf: chunk)
                        try consume(chunk)
                    }
                    if status == COMPRESSION_STATUS_END { reachedEnd = true; break }
                    if status == COMPRESSION_STATUS_ERROR { throw ArchiveReaderError.corruptDirectory }
                    if produced == 0 && stream.src_size == 0 { break }
                } while stream.src_size > 0 || (remaining == 0 && !reachedEnd)
            }
        }
        guard reachedEnd, remaining == 0 else { throw ArchiveReaderError.corruptDirectory }
    }

    private static func readDirectory(url: URL, limits: ArchiveReadLimits) throws -> [ArchiveEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw ArchiveReaderError.notZIP }
        let tailSize = min(size, 65_557)
        try handle.seek(toOffset: size - tailSize)
        guard let tail = try handle.read(upToCount: Int(tailSize)) else { throw ArchiveReaderError.notZIP }
        var endIndex: Int?
        if tail.count >= 22 {
            for index in stride(from: tail.count - 22, through: 0, by: -1) where tail.le32(index) == 0x06054b50 {
                endIndex = index
                break
            }
        }
        guard let endIndex else { throw ArchiveReaderError.notZIP }
        let endOffset = size - tailSize + UInt64(endIndex)
        var count = UInt64(tail.le16(endIndex + 10))
        var centralSize = UInt64(tail.le32(endIndex + 12))
        var centralOffset = UInt64(tail.le32(endIndex + 16))
        if count == UInt64(UInt16.max) || centralSize == UInt64(UInt32.max) || centralOffset == UInt64(UInt32.max) {
            guard endOffset >= 20 else { throw ArchiveReaderError.corruptDirectory }
            try handle.seek(toOffset: endOffset - 20)
            guard let locator = try handle.read(upToCount: 20), locator.count == 20,
                  locator.le32(0) == 0x07064b50 else { throw ArchiveReaderError.corruptDirectory }
            let end64Offset = locator.le64(8)
            guard end64Offset <= size - 56 else { throw ArchiveReaderError.corruptDirectory }
            try handle.seek(toOffset: end64Offset)
            guard let end64 = try handle.read(upToCount: 56), end64.count == 56,
                  end64.le32(0) == 0x06064b50 else { throw ArchiveReaderError.corruptDirectory }
            count = end64.le64(32)
            centralSize = end64.le64(40)
            centralOffset = end64.le64(48)
        }
        guard count <= UInt64(limits.maximumEntryCount) else { throw ArchiveReaderError.limitExceeded("entry_count") }
        guard centralSize <= limits.maximumCentralDirectoryBytes,
              centralOffset <= size, centralSize <= size - centralOffset,
              centralSize <= UInt64(Int.max) else { throw ArchiveReaderError.limitExceeded("central_directory") }
        try handle.seek(toOffset: centralOffset)
        guard let bytes = try handle.read(upToCount: Int(centralSize)), bytes.count == Int(centralSize) else {
            throw ArchiveReaderError.truncated("central_directory")
        }
        var cursor = 0
        var entries: [ArchiveEntry] = []
        var paths = Set<String>()
        var total: UInt64 = 0
        for _ in 0..<count {
            guard cursor <= bytes.count - 46, bytes.le32(cursor) == 0x02014b50 else {
                throw ArchiveReaderError.corruptDirectory
            }
            let flags = bytes.le16(cursor + 8)
            let method = bytes.le16(cursor + 10)
            let crc = bytes.le32(cursor + 16)
            let compressed32 = bytes.le32(cursor + 20)
            let size32 = bytes.le32(cursor + 24)
            let nameLength = Int(bytes.le16(cursor + 28))
            let extraLength = Int(bytes.le16(cursor + 30))
            let commentLength = Int(bytes.le16(cursor + 32))
            let offset32 = bytes.le32(cursor + 42)
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard recordLength >= 46, cursor <= bytes.count - recordLength else {
                throw ArchiveReaderError.corruptDirectory
            }
            let nameData = bytes.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let path = String(data: nameData, encoding: .utf8), ArchivePath.isSafe(path) else {
                throw ArchiveReaderError.unsafePath(String(data: nameData, encoding: .utf8) ?? "invalid")
            }
            guard paths.insert(path).inserted else { throw ArchiveReaderError.duplicatePath(path) }
            guard flags & 0x0001 == 0 else { throw ArchiveReaderError.encrypted(path) }
            guard method == 0 || method == 8 else { throw ArchiveReaderError.unsupportedCompression(path) }
            let extra = bytes.subdata(in: cursor + 46 + nameLength..<cursor + 46 + nameLength + extraLength)
            var compressed = UInt64(compressed32)
            var expanded = UInt64(size32)
            var localOffset = UInt64(offset32)
            if compressed32 == UInt32.max || size32 == UInt32.max || offset32 == UInt32.max {
                guard var values = zip64Values(extra) else { throw ArchiveReaderError.corruptDirectory }
                guard let resolvedExpanded = size32 == UInt32.max ? values.removeFirstSafe() : UInt64(size32),
                      let resolvedCompressed = compressed32 == UInt32.max ? values.removeFirstSafe() : UInt64(compressed32),
                      let resolvedOffset = offset32 == UInt32.max ? values.removeFirstSafe() : UInt64(offset32) else {
                    throw ArchiveReaderError.corruptDirectory
                }
                expanded = resolvedExpanded
                compressed = resolvedCompressed
                localOffset = resolvedOffset
            }
            guard expanded <= limits.maximumEntryBytes, compressed <= limits.maximumEntryBytes else {
                throw ArchiveReaderError.limitExceeded(path)
            }
            let (nextTotal, overflow) = total.addingReportingOverflow(expanded)
            guard !overflow, nextTotal <= limits.maximumTotalBytes else { throw ArchiveReaderError.limitExceeded("total_size") }
            total = nextTotal
            guard localOffset <= size - min(size, 30) else { throw ArchiveReaderError.truncated(path) }
            if !path.hasSuffix("/") {
                entries.append(ArchiveEntry(
                    path: path,
                    method: method,
                    crc32: crc,
                    compressedSize: compressed,
                    size: expanded,
                    localHeaderOffset: localOffset
                ))
            }
            cursor += recordLength
        }
        guard cursor <= bytes.count else { throw ArchiveReaderError.corruptDirectory }
        return entries
    }

    private static func zip64Values(_ extra: Data) -> [UInt64]? {
        var cursor = 0
        while cursor <= extra.count - 4 {
            let identifier = extra.le16(cursor)
            let length = Int(extra.le16(cursor + 2))
            guard cursor + 4 + length <= extra.count else { return nil }
            if identifier == 0x0001 {
                let payload = extra.subdata(in: cursor + 4..<cursor + 4 + length)
                guard payload.count % 8 == 0 else { return nil }
                return stride(from: 0, to: payload.count, by: 8).map { payload.le64($0) }
            }
            cursor += 4 + length
        }
        return nil
    }
}

struct ArchiveRestoreResult: Equatable {
    let albumCount: Int
    let trackCount: Int
    let playlistCount: Int
}

final class ArchiveRestorer {
    private let repository: CatalogRepository
    private let artworkStore: ArtworkStore
    private let mediaStore: MediaStore
    private let playbackStateStore: PlaybackStateStore
    private let restoreRoot: URL
    private let fileManager: FileManager

    init(
        repository: CatalogRepository,
        artworkStore: ArtworkStore,
        mediaStore: MediaStore,
        playbackStateStore: PlaybackStateStore,
        restoreRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.artworkStore = artworkStore
        self.mediaStore = mediaStore
        self.playbackStateStore = playbackStateStore
        self.restoreRoot = restoreRoot
        self.fileManager = fileManager
    }

    func restore(
        from source: URL,
        limits: ArchiveReadLimits = ArchiveReadLimits(),
        progress: (ArchiveExportProgress) -> Void = { _ in }
    ) throws -> ArchiveRestoreResult {
        let operationID = UUID().uuidString.lowercased()
        let staging = restoreRoot.appendingPathComponent(".incoming/\(operationID)", isDirectory: true)
        let finalMediaRoot = mediaStore.documentsMusicRoot
            .appendingPathComponent("_Restored/\(operationID)", isDirectory: true)
        var createdArtwork: [String] = []
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            let archive = try ArchiveReader(url: source, limits: limits, fileManager: fileManager)
            let extracted = try archive.extractAll(to: staging, progress: progress)
            guard let catalogEntry = archive.entries.first(where: { $0.path == ArchiveWriter.catalogFilename || ($0.path as NSString).lastPathComponent == ArchiveWriter.catalogFilename }),
                  let catalogURL = extracted[catalogEntry.path], catalogEntry.size <= 128 * 1_024 * 1_024 else {
                throw ArchiveReaderError.invalidCatalog("missing_catalog")
            }
            let catalog = try decodeCatalog(Data(contentsOf: catalogURL), entryPaths: Set(archive.entries.map(\.path)))
            try validate(catalog, entryPaths: Set(archive.entries.map(\.path)))

            var media: [String: MediaReference] = [:]
            try fileManager.createDirectory(at: finalMediaRoot, withIntermediateDirectories: true)
            for album in catalog.albums {
                for track in album.tracks {
                    if let path = track.audioPath, let stagedURL = extracted[path] {
                        let ext = stagedURL.pathExtension.lowercased()
                        guard !ext.isEmpty, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                            throw ArchiveReaderError.unsafePath(path)
                        }
                        let filename = "\(safeComponent(track.id)).\(ext)"
                        let destination = finalMediaRoot.appendingPathComponent(filename, isDirectory: false)
                        try fileManager.moveItem(at: stagedURL, to: destination)
                        media[track.id] = .documents(relativePath: "Music/_Restored/\(operationID)/\(filename)")
                    } else {
                        media[track.id] = .unavailable(trackID: track.id)
                    }
                }
            }

            var artwork: [String: String] = [:]
            let processor = ArtworkProcessor(store: artworkStore)
            for album in catalog.albums {
                guard let path = album.artworkPath, let stagedURL = extracted[path] else { continue }
                let key = "restore-\(operationID.prefix(8))-\(safeComponent(album.id).prefix(72))"
                guard let stored = processor.process(try Data(contentsOf: stagedURL), key: key) else {
                    throw ArchiveReaderError.invalidCatalog("artwork:\(album.id)")
                }
                artwork[album.id] = stored
                createdArtwork.append(stored)
            }

            try repository.restoreArchive(catalog, mediaReferences: media, artworkKeys: artwork)
            if let checkpoint = rewrittenCheckpoint(catalog.queueCheckpoint, media: media) {
                try playbackStateStore.save(checkpoint)
            }
            return ArchiveRestoreResult(
                albumCount: catalog.albums.count,
                trackCount: catalog.albums.reduce(0) { $0 + $1.tracks.count },
                playlistCount: catalog.playlists.count
            )
        } catch {
            try? fileManager.removeItem(at: finalMediaRoot)
            for key in createdArtwork { try? artworkStore.remove(key: key) }
            throw error
        }
    }

    private func decodeCatalog(_ data: Data, entryPaths: Set<String>) throws -> AeonArchiveCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = (root["v"] as? NSNumber)?.intValue else {
            throw ArchiveReaderError.invalidCatalog("json")
        }
        switch version {
        case 3:
            do { return try JSONDecoder().decode(AeonArchiveCatalog.self, from: data) }
            catch { throw ArchiveReaderError.invalidCatalog("native_v3") }
        case 1, 2:
            return try normalizeLegacy(root, version: version, entryPaths: entryPaths)
        default:
            throw ArchiveReaderError.unsupportedVersion(version)
        }
    }

    private func normalizeLegacy(
        _ root: [String: Any],
        version: Int,
        entryPaths: Set<String>
    ) throws -> AeonArchiveCatalog {
        guard let rawAlbums = root["albums"] as? [[String: Any]] else {
            throw ArchiveReaderError.invalidCatalog("legacy_albums")
        }
        let exported = ((root["exported"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1_000) / 1_000
        var albums: [AeonArchiveAlbum] = []
        for (albumIndex, rawAlbum) in rawAlbums.enumerated() {
            let id = try requiredString(rawAlbum["id"], "album_id")
            let title = try requiredString(rawAlbum["title"], "album_title")
            let artist = try requiredString(rawAlbum["artist"], "album_artist")
            guard let rawTracks = rawAlbum["tracks"] as? [[String: Any]] else {
                throw ArchiveReaderError.invalidCatalog("legacy_tracks")
            }
            let tracks = try rawTracks.enumerated().map { trackIndex, raw -> AeonArchiveTrack in
                let trackID = try requiredString(raw["id"], "track_id")
                let file = try requiredString(raw["file"], "track_file")
                guard entryPaths.contains(file) else { throw ArchiveReaderError.invalidCatalog("missing_audio:\(trackID)") }
                let sequence = (raw["idx"] as? NSNumber)?.intValue ?? trackIndex + 1
                return AeonArchiveTrack(
                    id: trackID,
                    albumID: id,
                    sequence: sequence,
                    discNumber: nil,
                    trackNumber: sequence,
                    title: try requiredString(raw["title"], "track_title"),
                    artist: (raw["artist"] as? String) ?? "",
                    duration: nil,
                    byteCount: 0,
                    mediaReference: .unavailable(trackID: trackID),
                    importedAt: exported,
                    audioPath: file
                )
            }
            let art = rawAlbum["artFile"] as? String
            if let art, !entryPaths.contains(art) { throw ArchiveReaderError.invalidCatalog("missing_artwork:\(id)") }
            albums.append(AeonArchiveAlbum(
                id: id,
                sequence: Int64((rawAlbum["seq"] as? NSNumber)?.intValue ?? albumIndex + 1),
                title: title,
                artist: artist,
                year: (rawAlbum["year"] as? String) ?? "",
                genre: (rawAlbum["genre"] as? String) ?? "",
                importedAt: exported,
                updatedAt: exported,
                artworkPath: art,
                tracks: tracks
            ))
        }
        var trackToAlbum: [String: String] = [:]
        for album in albums {
            for track in album.tracks {
                guard trackToAlbum.updateValue(album.id, forKey: track.id) == nil else {
                    throw ArchiveReaderError.invalidCatalog("track")
                }
            }
        }
        let playlists: [AeonArchivePlaylist] = try ((root["playlists"] as? [[String: Any]]) ?? []).map { raw in
            let id = try requiredString(raw["id"], "playlist_id")
            let items = (raw["items"] as? [[String: Any]]) ?? []
            let trackIDs = try items.map { item -> String in
                let trackID = try requiredString(item["trackId"], "playlist_track")
                let albumID = try requiredString(item["albumId"], "playlist_album")
                guard trackToAlbum[trackID] == albumID else { throw ArchiveReaderError.invalidCatalog("playlist_reference") }
                return trackID
            }
            return AeonArchivePlaylist(
                id: id,
                name: try requiredString(raw["name"], "playlist_name"),
                createdAt: exported,
                updatedAt: exported,
                trackIDs: trackIDs
            )
        }
        var listening: [AeonArchiveListening] = []
        if let plays = root["plays"] as? [String: Any] {
            for (key, rawValue) in plays {
                guard let value = rawValue as? NSNumber, value.int64Value >= 0 else { continue }
                let trackID = trackToAlbum[key] != nil ? key : albums.first(where: { $0.id == key })?.tracks.first?.id
                if let trackID {
                    listening.append(AeonArchiveListening(
                        trackID: trackID,
                        playCount: value.int64Value,
                        completedCount: 0,
                        lastPosition: 0,
                        lastPlayedAt: nil
                    ))
                }
            }
        }
        var settings: [AeonArchiveSetting] = []
        if let legacySettings = root["settings"] as? [String: Any],
           JSONSerialization.isValidJSONObject(legacySettings),
           let data = try? JSONSerialization.data(withJSONObject: legacySettings, options: [.sortedKeys]) {
            settings.append(AeonArchiveSetting(key: "legacy.settings", value: data, updatedAt: exported))
            if let enabled = legacySettings["metadataLookups"] as? Bool {
                settings.append(AeonArchiveSetting(
                    key: MetadataEnricher.lookupEnabledKey,
                    value: try JSONEncoder().encode(enabled),
                    updatedAt: exported
                ))
            }
        }
        let skySeed = (root["skySeed"] as? NSNumber).map { UInt32(truncating: $0) }
        if let skySeed {
            settings.append(AeonArchiveSetting(
                key: "sky.seed",
                value: try JSONEncoder().encode(skySeed),
                updatedAt: exported
            ))
        }
        return AeonArchiveCatalog(
            v: 3,
            compatibilityVersion: version,
            exportedAt: exported,
            albums: albums,
            playlists: playlists,
            listening: listening,
            settings: settings,
            queueCheckpoint: legacyCheckpoint(root["lastPlayed"] as? [String: Any], albums: albums),
            skySeed: skySeed,
            skyRecords: []
        )
    }

    private func validate(_ catalog: AeonArchiveCatalog, entryPaths: Set<String>) throws {
        guard catalog.v == 3 else { throw ArchiveReaderError.unsupportedVersion(catalog.v) }
        var albumIDs = Set<String>()
        var trackIDs = Set<String>()
        var sequences = Set<Int64>()
        for album in catalog.albums {
            guard validID(album.id), !album.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !album.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  album.sequence > 0, sequences.insert(album.sequence).inserted,
                  albumIDs.insert(album.id).inserted else { throw ArchiveReaderError.invalidCatalog("album") }
            if let artwork = album.artworkPath {
                guard ArchivePath.isSafe(artwork), entryPaths.contains(artwork) else { throw ArchiveReaderError.invalidCatalog("artwork") }
            }
            var trackSequences = Set<Int>()
            for track in album.tracks {
                guard validID(track.id), track.albumID == album.id, track.sequence > 0,
                      trackSequences.insert(track.sequence).inserted,
                      trackIDs.insert(track.id).inserted,
                      !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      track.byteCount >= 0 else { throw ArchiveReaderError.invalidCatalog("track") }
                if let audio = track.audioPath {
                    guard ArchivePath.isSafe(audio), entryPaths.contains(audio) else { throw ArchiveReaderError.invalidCatalog("audio") }
                } else {
                    switch track.mediaReference {
                    case .unavailable, .legacyBlob: break
                    case .native, .documents, .externalBookmark:
                        throw ArchiveReaderError.invalidCatalog("missing_audio:\(track.id)")
                    }
                }
            }
        }
        var playlistIDs = Set<String>()
        for playlist in catalog.playlists {
            guard validID(playlist.id), playlistIDs.insert(playlist.id).inserted,
                  !playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  playlist.trackIDs.allSatisfy(trackIDs.contains) else {
                throw ArchiveReaderError.invalidCatalog("playlist")
            }
        }
        guard catalog.listening.allSatisfy({ trackIDs.contains($0.trackID) && $0.playCount >= 0 && $0.completedCount >= 0 }),
              Set(catalog.settings.map(\.key)).count == catalog.settings.count,
              Set(catalog.skyRecords.map(\.id)).count == catalog.skyRecords.count else {
            throw ArchiveReaderError.invalidCatalog("relationship")
        }
        if let queue = catalog.queueCheckpoint {
            guard queue.queue.allSatisfy({ trackIDs.contains($0.trackID) && albumIDs.contains($0.albumID) }) else {
                throw ArchiveReaderError.invalidCatalog("queue")
            }
        }
    }

    private func rewrittenCheckpoint(_ value: PlaybackSnapshot?, media: [String: MediaReference]) -> PlaybackSnapshot? {
        guard let value else { return nil }
        let queue = value.queue.compactMap { item -> QueueItem? in
            guard let reference = media[item.trackID] else { return nil }
            return QueueItem(trackID: item.trackID, albumID: item.albumID, mediaRef: reference)
        }
        guard !queue.isEmpty else { return nil }
        let index = min(max(0, value.queueIndex ?? 0), queue.count - 1)
        return PlaybackSnapshot(
            version: value.version,
            trackID: queue[index].trackID,
            queueRevision: value.queueRevision,
            queue: queue,
            queueIndex: index,
            position: value.position,
            intent: .paused,
            replayGainMode: value.replayGainMode,
            replayGainPreampDB: value.replayGainPreampDB,
            masterVolume: value.masterVolume,
            eqEnabled: value.eqEnabled,
            eqBands: value.eqBands,
            repeatMode: value.repeatMode,
            route: nil,
            sourceFormat: nil,
            outputFormat: nil,
            timestamp: Date()
        )
    }

    private func legacyCheckpoint(_ raw: [String: Any]?, albums: [AeonArchiveAlbum]) -> PlaybackSnapshot? {
        guard let raw, let items = raw["queue"] as? [[String: Any]] else { return nil }
        var tracks: [String: AeonArchiveTrack] = [:]
        for album in albums {
            for track in album.tracks where tracks[track.id] == nil { tracks[track.id] = track }
        }
        let queue = items.compactMap { item -> QueueItem? in
            guard let trackID = item["trackId"] as? String, let albumID = item["albumId"] as? String,
                  let track = tracks[trackID], track.albumID == albumID else { return nil }
            return QueueItem(trackID: trackID, albumID: albumID, mediaRef: .unavailable(trackID: trackID))
        }
        guard !queue.isEmpty else { return nil }
        let index = min(max(0, (raw["qIndex"] as? NSNumber)?.intValue ?? 0), queue.count - 1)
        return PlaybackSnapshot(
            version: 0,
            trackID: queue[index].trackID,
            queueRevision: 0,
            queue: queue,
            queueIndex: index,
            position: 0,
            intent: .paused,
            replayGainMode: .off,
            replayGainPreampDB: 0,
            masterVolume: 0.9,
            eqEnabled: false,
            eqBands: EQView.frequencies.map { EQBand(frequency: $0, q: 1, gainDB: 0) },
            route: nil,
            sourceFormat: nil,
            outputFormat: nil,
            timestamp: Date()
        )
    }

    private func requiredString(_ value: Any?, _ field: String) throws -> String {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArchiveReaderError.invalidCatalog(field)
        }
        return value
    }

    private func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 && !value.contains("\0") }

    private func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(mapped).prefix(120).description
    }
}

private extension Array where Element == UInt64 {
    mutating func removeFirstSafe() -> UInt64? { isEmpty ? nil : removeFirst() }
}

private extension Data {
    func le16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func le32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    func le64(_ offset: Int) -> UInt64 {
        UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32
    }
}
