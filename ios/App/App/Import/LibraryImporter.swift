import CryptoKit
import Foundation

enum LibraryImportPhase: String, Equatable {
    case scanning
    case readingMetadata
    case grouping
    case committing
    case complete
}

struct LibraryImportProgress: Equatable {
    let phase: LibraryImportPhase
    let completedFiles: Int
    let totalFiles: Int
    let completedGroups: Int
    let totalGroups: Int
}

struct LibraryImportResult: Equatable {
    var importedAlbums = 0
    var importedTracks = 0
    var failedFiles: [URL] = []
    var skippedDuplicateAlbums: [String] = []
}

enum LibraryImportError: Error, Equatable {
    case cancelled
    case noSupportedAudio
}

final class LibraryImportCancellation {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    fileprivate func check() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { throw LibraryImportError.cancelled }
    }
}

final class LibraryImporter: @unchecked Sendable {
    static let maximumConcurrentProbes = 4

    private struct Cursor: Codable, Equatable {
        let signature: String
        let nextGroup: Int
    }

    private struct ProbedCandidate {
        let candidate: ImportCandidate
        let media: ProbedMedia
        let byteCount: Int64
    }

    private let repository: CatalogRepository
    private let mediaStore: MediaStore
    private let tagReader: AudioTagReading
    private let artworkProcessor: ArtworkProcessor
    private let metadataProbe: MediaProbing
    private let metadataEnricher: MetadataEnricher?
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        repository: CatalogRepository,
        mediaStore: MediaStore,
        tagReader: AudioTagReading,
        artworkProcessor: ArtworkProcessor,
        metadataProbe: MediaProbing,
        metadataEnricher: MetadataEnricher?,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.mediaStore = mediaStore
        self.tagReader = tagReader
        self.artworkProcessor = artworkProcessor
        self.metadataProbe = metadataProbe
        self.metadataEnricher = metadataEnricher
        self.fileManager = fileManager
        self.now = now
    }

    func importURLs(
        _ selectedURLs: [URL],
        mode: LibraryImportGroupingMode,
        cancellation: LibraryImportCancellation = LibraryImportCancellation(),
        progress: @escaping (LibraryImportProgress) -> Void = { _ in }
    ) async throws -> LibraryImportResult {
        let accessed = selectedURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

        try cancellation.check()
        progress(LibraryImportProgress(
            phase: .scanning, completedFiles: 0, totalFiles: 0, completedGroups: 0, totalGroups: 0
        ))
        let files = try collectAudioFiles(selectedURLs, cancellation: cancellation)
        guard !files.isEmpty else { throw LibraryImportError.noSupportedAudio }
        let signature = selectionSignature(files: files, mode: mode)
        let cursorKey = "library.import.cursor.\(signature)"

        var result = LibraryImportResult()
        var candidates: [ImportCandidate] = []
        candidates.reserveCapacity(files.count)
        for (index, entry) in files.enumerated() {
            try cancellation.check()
            do {
                let tags = try await tagReader.read(url: entry.url, includeArtwork: false)
                candidates.append(ImportCandidate(
                    url: entry.url,
                    folder: entry.url.deletingLastPathComponent().lastPathComponent,
                    folderKey: entry.url.deletingLastPathComponent().standardizedFileURL.path,
                    batchLabel: entry.batchLabel,
                    tags: tags,
                    selectionIndex: index
                ))
            } catch {
                result.failedFiles.append(entry.url)
            }
            progress(LibraryImportProgress(
                phase: .readingMetadata,
                completedFiles: index + 1,
                totalFiles: files.count,
                completedGroups: 0,
                totalGroups: 0
            ))
        }

        try cancellation.check()
        let groups = ImportGrouper.group(candidates, mode: mode)
        progress(LibraryImportProgress(
            phase: .grouping,
            completedFiles: files.count,
            totalFiles: files.count,
            completedGroups: 0,
            totalGroups: groups.count
        ))
        let savedCursor = try repository.setting(Cursor.self, forKey: cursorKey)
        let startIndex = savedCursor?.signature == signature ? min(savedCursor?.nextGroup ?? 0, groups.count) : 0

        for groupIndex in startIndex ..< groups.count {
            try cancellation.check()
            let group = ImportGrouper.sortAlbumItems(groups[groupIndex])
            let groupResult = try await importGroup(group, result: &result, cancellation: cancellation)
            result.importedAlbums += groupResult.albumCount
            result.importedTracks += groupResult.trackCount
            if let duplicate = groupResult.duplicate { result.skippedDuplicateAlbums.append(duplicate) }
            try repository.setSetting(Cursor(signature: signature, nextGroup: groupIndex + 1), forKey: cursorKey, at: now())
            progress(LibraryImportProgress(
                phase: .committing,
                completedFiles: files.count,
                totalFiles: files.count,
                completedGroups: groupIndex + 1,
                totalGroups: groups.count
            ))
        }
        try cancellation.check()
        try repository.removeSetting(forKey: cursorKey)
        progress(LibraryImportProgress(
            phase: .complete,
            completedFiles: files.count,
            totalFiles: files.count,
            completedGroups: groups.count,
            totalGroups: groups.count
        ))
        return result
    }

    private func importGroup(
        _ group: [ImportCandidate],
        result: inout LibraryImportResult,
        cancellation: LibraryImportCancellation
    ) async throws -> (albumCount: Int, trackCount: Int, duplicate: String?) {
        guard !group.isEmpty else { return (0, 0, nil) }
        var playable: [ProbedCandidate] = []
        for candidate in group {
            try cancellation.check()
            guard case .playable(let media) = metadataProbe.probe(url: candidate.url) else {
                result.failedFiles.append(candidate.url)
                continue
            }
            let size = (try? candidate.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            playable.append(ProbedCandidate(candidate: candidate, media: media, byteCount: size))
        }
        guard !playable.isEmpty else { return (0, 0, nil) }

        var fields = ImportGrouper.albumFields(
            for: playable.map(\.candidate),
            batchLabel: playable.first?.candidate.batchLabel ?? ""
        )
        if fields.genre == nil,
           let metadataEnricher,
           let enriched = try? await metadataEnricher.automaticGenre(for: fields.artist) {
            fields = ImportAlbumFields(title: fields.title, artist: fields.artist, year: fields.year, genre: enriched)
        }
        if try isDuplicate(fields: fields, trackCount: playable.count) {
            return (0, 0, fields.title)
        }

        let timestamp = now()
        let albumID = UUID().uuidString.lowercased()
        let sequence = (try repository.albumPage(offset: 0, limit: 1, sort: .recentlyAdded).first?.sequence ?? 0) + 1
        var storedReferences: [MediaReference] = []
        var storedArtworkKey: String?
        var committed = false
        defer {
            if !committed {
                storedReferences.forEach(mediaStore.removeImportedDocument)
                if let storedArtworkKey { try? artworkProcessor.remove(key: storedArtworkKey) }
            }
        }
        var tracks: [CatalogTrack] = []
        for (index, item) in playable.enumerated() {
            try cancellation.check()
            let trackID = UUID().uuidString.lowercased()
            do {
                let reference = try mediaStore.importIntoDocuments(
                    sourceURL: item.candidate.url,
                    albumID: albumID,
                    trackID: trackID
                ) { [metadataProbe] partial in
                    if case .playable = metadataProbe.probe(url: partial) { return true }
                    return false
                }
                storedReferences.append(reference)
                let inferred = ImportGrouper.trackNumbers(from: item.candidate.url.lastPathComponent)
                tracks.append(CatalogTrack(
                    id: trackID,
                    albumID: albumID,
                    sequence: index + 1,
                    discNumber: item.candidate.tags.discNumber ?? inferred.disc,
                    trackNumber: item.candidate.tags.trackNumber ?? inferred.track,
                    title: clean(item.candidate.tags.title) ?? item.candidate.url.deletingPathExtension().lastPathComponent,
                    artist: clean(item.candidate.tags.artist) ?? fields.artist,
                    duration: item.media.descriptor.duration,
                    byteCount: item.byteCount,
                    mediaReference: reference,
                    importedAt: timestamp
                ))
            } catch {
                result.failedFiles.append(item.candidate.url)
            }
        }
        guard !tracks.isEmpty else { return (0, 0, nil) }

        let artworkKey = await artwork(for: playable.map(\.candidate), albumID: albumID)
        storedArtworkKey = artworkKey
        let album = CatalogAlbum(
            id: albumID,
            sequence: sequence,
            title: fields.title,
            artist: fields.artist,
            year: fields.year ?? "",
            genre: fields.genre ?? "",
            artworkKey: artworkKey,
            importedAt: timestamp,
            updatedAt: timestamp
        )
        do {
            try repository.insertAlbum(album, tracks: tracks)
            committed = true
            return (1, tracks.count, nil)
        } catch {
            throw error
        }
    }

    private func artwork(for group: [ImportCandidate], albumID: String) async -> String? {
        for candidate in group {
            if let tags = try? await tagReader.read(url: candidate.url, includeArtwork: true),
               let key = artworkProcessor.process(tags.artworkData, key: albumID) {
                return key
            }
        }
        let names = ["cover", "folder", "front", "album", "artwork"]
        let directories = Array(Set(group.map { $0.url.deletingLastPathComponent().standardizedFileURL }))
        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let candidates = files.filter {
                ["jpg", "jpeg", "png", "heic", "heif"].contains($0.pathExtension.lowercased())
            }.sorted { left, right in
                let leftRank = names.firstIndex(of: left.deletingPathExtension().lastPathComponent.lowercased()) ?? names.count
                let rightRank = names.firstIndex(of: right.deletingPathExtension().lastPathComponent.lowercased()) ?? names.count
                return leftRank == rightRank
                    ? left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
                    : leftRank < rightRank
            }
            for candidate in candidates {
                guard let size = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 32 * 1_024 * 1_024,
                      let data = try? Data(contentsOf: candidate),
                      let key = artworkProcessor.process(data, key: albumID) else { continue }
                return key
            }
        }
        return nil
    }

    private func isDuplicate(fields: ImportAlbumFields, trackCount: Int) throws -> Bool {
        var offset = 0
        while true {
            let page = try repository.albumPage(
                offset: offset,
                limit: CatalogDatabase.maximumPageSize,
                sort: .recentlyAdded
            )
            if page.contains(where: {
                ImportGrouper.isDuplicate(
                    existingTitle: $0.title,
                    existingArtist: $0.artist,
                    existingTrackCount: $0.trackCount,
                    candidate: fields,
                    candidateTrackCount: trackCount
                )
            }) { return true }
            if page.count < CatalogDatabase.maximumPageSize { return false }
            offset += page.count
        }
    }

    private func collectAudioFiles(
        _ selectedURLs: [URL],
        cancellation: LibraryImportCancellation
    ) throws -> [(url: URL, batchLabel: String)] {
        var collected: [(URL, String)] = []
        var seen = Set<String>()
        for selected in selectedURLs {
            try cancellation.check()
            let values = try? selected.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let batchLabel = values?.isDirectory == true
                ? selected.lastPathComponent
                : selected.deletingLastPathComponent().lastPathComponent
            let candidates: [URL]
            if values?.isDirectory == true {
                let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
                candidates = fileManager.enumerator(
                    at: selected,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )?.compactMap { $0 as? URL } ?? []
            } else {
                candidates = [selected]
            }
            for candidate in candidates {
                try cancellation.check()
                let resource = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard resource?.isRegularFile == true,
                      resource?.isSymbolicLink != true,
                      AudioTagReader.supportedExtensions.contains(candidate.pathExtension.lowercased()) else { continue }
                let key = candidate.standardizedFileURL.resolvingSymlinksInPath().path
                if seen.insert(key).inserted { collected.append((candidate, batchLabel)) }
            }
        }
        return collected.sorted {
            $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending
        }
    }

    private func selectionSignature(
        files: [(url: URL, batchLabel: String)],
        mode: LibraryImportGroupingMode
    ) -> String {
        var content = mode.rawValue + "\n"
        for entry in files {
            let values = try? entry.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            content += entry.url.standardizedFileURL.path
            content += "\u{0}\(values?.fileSize ?? -1)\u{0}\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)\n"
        }
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
