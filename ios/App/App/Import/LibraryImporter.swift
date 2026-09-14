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
    /// Every selected location refused to open. Usually a revoked security-scoped grant
    /// or a provider (a network share, a detached external drive) that is not mounted.
    case accessDenied
    /// The files are known but their contents never arrived from iCloud.
    case sourceUnavailable
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
    private let downloadTimeout: TimeInterval

    init(
        repository: CatalogRepository,
        mediaStore: MediaStore,
        tagReader: AudioTagReading,
        artworkProcessor: ArtworkProcessor,
        metadataProbe: MediaProbing,
        metadataEnricher: MetadataEnricher?,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        downloadTimeout: TimeInterval = 120
    ) {
        self.downloadTimeout = downloadTimeout
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

        // A location that is still unreachable once its grant has been claimed is one
        // Aeon genuinely cannot read: an unmounted provider, or a bookmark the system
        // has revoked. Report it rather than finishing with an empty, silent success.
        let unreachable = selectedURLs.filter { (try? $0.checkResourceIsReachable()) != true }
        if !selectedURLs.isEmpty, unreachable.count == selectedURLs.count {
            throw LibraryImportError.accessDenied
        }

        try cancellation.check()
        progress(LibraryImportProgress(
            phase: .scanning, completedFiles: 0, totalFiles: 0, completedGroups: 0, totalGroups: 0
        ))
        let files = try collectAudioFiles(selectedURLs, cancellation: cancellation)
        guard !files.isEmpty else { throw LibraryImportError.noSupportedAudio }
        let signature = selectionSignature(files: files, mode: mode)
        let cursorKey = "library.import.cursor.\(signature)"

        var result = LibraryImportResult()
        var undownloadedFiles = 0
        var candidates: [ImportCandidate] = []
        candidates.reserveCapacity(files.count)
        for (index, entry) in files.enumerated() {
            try cancellation.check()
            do {
                try await materialize(entry.url)
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
                if (error as? LibraryImportError) == .sourceUnavailable { undownloadedFiles += 1 }
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

        // Every file was found but none could be read. Report why rather than finishing
        // with a successful import of nothing.
        if candidates.isEmpty, !result.failedFiles.isEmpty {
            throw undownloadedFiles == result.failedFiles.count
                ? LibraryImportError.sourceUnavailable
                : LibraryImportError.noSupportedAudio
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
                // Hidden entries are filtered below rather than by the enumerator: an
                // iCloud Drive file that has not been downloaded is on disk only as a
                // hidden ".<name>.icloud" placeholder, and skipping those makes a folder
                // full of music look empty.
                var walked: [URL] = []
                if let enumerator = fileManager.enumerator(
                    at: selected,
                    includingPropertiesForKeys: keys,
                    options: [.skipsPackageDescendants]
                ) {
                    while let entry = enumerator.nextObject() as? URL {
                        let name = entry.lastPathComponent
                        let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                        if isDirectory, name.hasPrefix(".") {
                            enumerator.skipDescendants()
                            continue
                        }
                        walked.append(entry)
                    }
                }
                candidates = walked
            } else {
                candidates = [selected]
            }
            for candidate in candidates {
                try cancellation.check()
                guard let target = audioTarget(for: candidate) else { continue }
                let key = target.standardizedFileURL.resolvingSymlinksInPath().path
                if seen.insert(key).inserted { collected.append((target, batchLabel)) }
            }
        }
        return collected.sorted {
            $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending
        }
    }

    /// Maps a directory entry to the audio file it stands for, or nil when it is not one
    /// Aeon can read. An undownloaded iCloud item is represented on disk by a hidden
    /// ".<name>.icloud" placeholder; the real file is what gets imported, after
    /// `materialize` pulls its contents down.
    private func audioTarget(for candidate: URL) -> URL? {
        let name = candidate.lastPathComponent
        if name.hasPrefix("."), name.hasSuffix(Self.ubiquitousPlaceholderSuffix) {
            let realName = String(name.dropFirst().dropLast(Self.ubiquitousPlaceholderSuffix.count))
            guard !realName.isEmpty else { return nil }
            let target = candidate.deletingLastPathComponent().appendingPathComponent(realName, isDirectory: false)
            guard AudioTagReader.supportedExtensions.contains(target.pathExtension.lowercased()) else { return nil }
            return target
        }
        guard !name.hasPrefix(".") else { return nil }
        let resource = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resource?.isRegularFile == true,
              resource?.isSymbolicLink != true,
              AudioTagReader.supportedExtensions.contains(candidate.pathExtension.lowercased()) else { return nil }
        return candidate
    }

    /// Waits for an iCloud item's contents to arrive before anything tries to read it.
    /// Local files return immediately.
    private func materialize(_ url: URL) async throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let values = try? url.resourceValues(forKeys: keys)
        // Either the item is on disk and flagged ubiquitous, or nothing is there yet and
        // only its ".icloud" placeholder stands in for it.
        let placeholderOnly = values == nil
            && fileManager.fileExists(atPath: ubiquitousPlaceholderURL(for: url).path)
        guard values?.isUbiquitousItem == true || placeholderOnly else { return }
        if values?.ubiquitousItemDownloadingStatus == .current { return }
        try? fileManager.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(downloadTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
            guard let status = try? url.resourceValues(forKeys: keys).ubiquitousItemDownloadingStatus else { continue }
            if status == .current { return }
        }
        throw LibraryImportError.sourceUnavailable
    }

    private func ubiquitousPlaceholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent)\(Self.ubiquitousPlaceholderSuffix)", isDirectory: false)
    }

    private static let ubiquitousPlaceholderSuffix = ".icloud"

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
