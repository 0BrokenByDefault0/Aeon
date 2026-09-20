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
    var repairedTracks = 0
    var updatedTracks = 0
    var unchangedFiles = 0
    var missingFiles = 0
    var failureReasons: [String] = []

    /// A completed pipeline is not necessarily a successful import. Always report the outcome.
    var userMessage: String {
        var parts: [String] = []
        if importedTracks > 0 {
            parts.append("Added \(importedTracks) track\(importedTracks == 1 ? "" : "s") in \(importedAlbums) album\(importedAlbums == 1 ? "" : "s") to Library.")
        } else if repairedTracks > 0 {
            parts.append("Re-linked \(repairedTracks) adopted track\(repairedTracks == 1 ? "" : "s") to \(repairedTracks == 1 ? "its" : "their") current Files location.")
        } else if updatedTracks > 0 {
            parts.append("Updated \(updatedTracks) changed track\(updatedTracks == 1 ? "" : "s") without rescanning unchanged music.")
        } else if unchangedFiles > 0 {
            parts.append("Your Library is current. \(unchangedFiles) unchanged file\(unchangedFiles == 1 ? " was" : "s were") skipped.")
        } else if !failedFiles.isEmpty {
            parts.append("No tracks were imported.")
        } else if !skippedDuplicateAlbums.isEmpty {
            parts.append("This music is already in your Library. No duplicate tracks were added.")
        } else {
            parts.append("No new tracks were imported.")
        }
        if !failedFiles.isEmpty {
            parts.append("\(failedFiles.count) file\(failedFiles.count == 1 ? "" : "s") could not be imported.")
            let details = failureReasons.isEmpty ? failedFiles.map(\.lastPathComponent) : failureReasons
            parts.append(contentsOf: details.prefix(3))
        }
        if importedTracks > 0 && !skippedDuplicateAlbums.isEmpty {
            parts.append("\(skippedDuplicateAlbums.count) existing album\(skippedDuplicateAlbums.count == 1 ? "" : "s") skipped.")
        }
        if importedTracks > 0 && repairedTracks > 0 {
            parts.append("Re-linked \(repairedTracks) adopted track\(repairedTracks == 1 ? "" : "s") to \(repairedTracks == 1 ? "its" : "their") current Files location.")
        }
        if importedTracks > 0 && unchangedFiles > 0 {
            parts.append("Skipped \(unchangedFiles) unchanged file\(unchangedFiles == 1 ? "" : "s") using the import index.")
        }
        if missingFiles > 0 {
            parts.append("\(missingFiles) indexed file\(missingFiles == 1 ? " is" : "s are") currently missing; catalogue entries were preserved.")
        }
        return parts.joined(separator: "\n\n")
    }

    mutating func recordFailure(_ url: URL, stage: String, error: Error? = nil) {
        failedFiles.append(url)
        // Keep actionable stage/code evidence, not an external provider's full private path.
        if failureReasons.count < 3 {
            let code = error.map { " (\(($0 as NSError).domain) \(($0 as NSError).code))" } ?? ""
            failureReasons.append("\(url.lastPathComponent): \(stage)\(code).")
        }
    }
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
    private static let adoptedIndexKey = "library.import.adopted-index.v1"

    private struct Cursor: Codable, Equatable {
        let signature: String
        let nextGroup: Int
    }

    private struct ProbedCandidate {
        let candidate: ImportCandidate
        let media: ProbedMedia
        let byteCount: Int64
    }

    private struct CollectedAudioFile {
        let url: URL
        let batchLabel: String
        let relativePath: String?
        let fileSize: Int64
        let modificationTime: TimeInterval?
        let resourceIdentifier: String?
    }

    private struct AdoptedImportIndex: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var relativePath: String
            var fileSize: Int64
            var modificationTime: TimeInterval?
            var resourceIdentifier: String?
            var trackID: String?
            var albumID: String?
            var missing: Bool
        }
        var entries: [Entry]
    }

    private struct AdoptionPlan {
        var unchanged: [(CollectedAudioFile, AdoptedImportIndex.Entry)] = []
        var new: [CollectedAudioFile] = []
        var modified: [(CollectedAudioFile, AdoptedImportIndex.Entry)] = []
        var moved: [(CollectedAudioFile, AdoptedImportIndex.Entry)] = []
        var missing: [AdoptedImportIndex.Entry] = []
    }

    private enum ScanPolicy: Equatable {
        case selectedSources
        case adoptedMusicRoot
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
        try await importURLs(
            selectedURLs,
            mode: mode,
            scanPolicy: .selectedSources,
            cancellation: cancellation,
            progress: progress
        )
    }

    /// Scans Aeon's own Files-visible Music directory and adopts audio in place.
    /// No security-scoped external-folder grant is needed and no audio is copied.
    /// Keep this on the import-area native validation route: adopted media must remain
    /// resolvable by the production playback engine after every storage change.
    func adoptMusicLibrary(
        cancellation: LibraryImportCancellation = LibraryImportCancellation(),
        progress: @escaping (LibraryImportProgress) -> Void = { _ in }
    ) async throws -> LibraryImportResult {
        try await importURLs(
            [mediaStore.documentsMusicRoot],
            mode: .folder,
            scanPolicy: .adoptedMusicRoot,
            cancellation: cancellation,
            progress: progress
        )
    }

    private func importURLs(
        _ selectedURLs: [URL],
        mode: LibraryImportGroupingMode,
        scanPolicy: ScanPolicy,
        cancellation: LibraryImportCancellation,
        progress: @escaping (LibraryImportProgress) -> Void
    ) async throws -> LibraryImportResult {
        let accessed: [URL]
        if scanPolicy == .selectedSources {
            accessed = selectedURLs.filter { $0.startAccessingSecurityScopedResource() }
        } else {
            accessed = []
        }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

        // A location that is still unreachable once its grant has been claimed is one
        // Aeon genuinely cannot read: an unmounted provider, or a bookmark the system
        // has revoked. App-owned Music does not require a scoped grant.
        let unreachable = selectedURLs.filter { (try? $0.checkResourceIsReachable()) != true }
        if !selectedURLs.isEmpty, unreachable.count == selectedURLs.count {
            throw LibraryImportError.accessDenied
        }

        try cancellation.check()
        progress(LibraryImportProgress(
            phase: .scanning, completedFiles: 0, totalFiles: 0, completedGroups: 0, totalGroups: 0
        ))
        let discoveredFiles = try collectAudioFiles(
            selectedURLs,
            scanPolicy: scanPolicy,
            cancellation: cancellation
        )
        var result = LibraryImportResult()
        var files = discoveredFiles
        var priorAdoptedIndex: AdoptedImportIndex?
        if scanPolicy == .adoptedMusicRoot {
            let stored = try repository.setting(AdoptedImportIndex.self, forKey: Self.adoptedIndexKey)
            priorAdoptedIndex = try stored ?? bootstrapAdoptedIndex(from: discoveredFiles)
            if discoveredFiles.isEmpty, let priorAdoptedIndex, !priorAdoptedIndex.entries.isEmpty {
                result.missingFiles = priorAdoptedIndex.entries.count
                var missing = priorAdoptedIndex
                for index in missing.entries.indices { missing.entries[index].missing = true }
                try repository.setSetting(missing, forKey: Self.adoptedIndexKey, at: now())
                progress(LibraryImportProgress(
                    phase: .complete, completedFiles: 0, totalFiles: 0, completedGroups: 0, totalGroups: 0
                ))
                return result
            }
            if let priorAdoptedIndex {
                let plan = classifyAdoptedFiles(discoveredFiles, against: priorAdoptedIndex)
                result.unchangedFiles = plan.unchanged.count
                result.missingFiles = plan.missing.count
                var delta = plan.new
                for (file, entry) in plan.moved {
                    if try relinkAdoptedTrack(entry, to: file) { result.repairedTracks += 1 }
                    else { delta.append(file) }
                }
                for (file, entry) in plan.modified {
                    do {
                        if try await refreshAdoptedTrack(entry, from: file, cancellation: cancellation) {
                            result.updatedTracks += 1
                        } else {
                            delta.append(file)
                        }
                    } catch LibraryImportError.cancelled {
                        throw LibraryImportError.cancelled
                    } catch {
                        result.recordFailure(file.url, stage: "could not refresh changed audio", error: error)
                    }
                }
                // `files` began as the complete scan. Incremental work is only the
                // classified delta; unchanged entries never reach tag/probe stages.
                files = delta
            }
        }
        guard !discoveredFiles.isEmpty else { throw LibraryImportError.noSupportedAudio }
        if files.isEmpty {
            if scanPolicy == .adoptedMusicRoot {
                try persistAdoptedIndex(files: discoveredFiles, previous: priorAdoptedIndex)
            }
            progress(LibraryImportProgress(
                phase: .complete, completedFiles: 0, totalFiles: 0, completedGroups: 0, totalGroups: 0
            ))
            return result
        }
        let signature = selectionSignature(files: files, mode: mode)
        let cursorKey = "library.import.cursor.\(signature)"

        // Decode only stable local snapshots for external providers. Music already under
        // Documents/Music stays in place and is read directly.
        let stagingRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "AeonImport-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingRoot) }
        var originalURLs: [URL: URL] = [:]
        var undownloadedFiles = 0
        var candidates: [ImportCandidate] = []
        candidates.reserveCapacity(files.count)
        for (index, entry) in files.enumerated() {
            try cancellation.check()
            do {
                try await materialize(entry.url)
                let localURL = try stageSource(entry.url, index: index, root: stagingRoot, cancellation: cancellation)
                originalURLs[localURL] = entry.url
                let tags = try await tagReader.read(url: localURL, includeArtwork: false)
                candidates.append(ImportCandidate(
                    url: localURL,
                    folder: entry.url.deletingLastPathComponent().lastPathComponent,
                    folderKey: entry.url.deletingLastPathComponent().standardizedFileURL.path,
                    batchLabel: entry.batchLabel,
                    tags: tags,
                    selectionIndex: index
                ))
            } catch LibraryImportError.cancelled {
                throw LibraryImportError.cancelled
            } catch {
                if (error as? LibraryImportError) == .sourceUnavailable { undownloadedFiles += 1 }
                result.recordFailure(entry.url, stage: "could not read a local copy", error: error)
            }
            progress(LibraryImportProgress(
                phase: .readingMetadata,
                completedFiles: index + 1,
                totalFiles: files.count,
                completedGroups: 0,
                totalGroups: 0
            ))
        }

        if candidates.isEmpty, !result.failedFiles.isEmpty {
            if undownloadedFiles == result.failedFiles.count { throw LibraryImportError.sourceUnavailable }
            return result
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
            let groupResult = try await importGroup(
                group,
                originalURLs: originalURLs,
                result: &result,
                cancellation: cancellation
            )
            result.importedAlbums += groupResult.albumCount
            result.importedTracks += groupResult.trackCount
            result.repairedTracks += groupResult.repairedTracks
            if let duplicate = groupResult.duplicate { result.skippedDuplicateAlbums.append(duplicate) }
            try repository.setSetting(
                Cursor(signature: signature, nextGroup: groupIndex + 1),
                forKey: cursorKey,
                at: now()
            )
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
        if scanPolicy == .adoptedMusicRoot {
            try persistAdoptedIndex(files: discoveredFiles, previous: priorAdoptedIndex)
        }
        progress(LibraryImportProgress(
            phase: .complete,
            completedFiles: files.count,
            totalFiles: files.count,
            completedGroups: groups.count,
            totalGroups: groups.count
        ))
        return result
    }

    private func stageSource(_ source: URL, index: Int, root: URL, cancellation: LibraryImportCancellation) throws -> URL {
        // Preserve the established no-copy behavior for music already owned by this app.
        if mediaStore.adoptedDocumentReference(for: source) != nil { return source }
        let directory = root.appendingPathComponent(String(index), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
        return try coordinatedRead(source) { coordinatedURL in
            try cancellation.check()
            try fileManager.copyItem(at: coordinatedURL, to: destination)
            try cancellation.check()
            return destination
        }
    }

    /// Use the URL supplied by the accessor: a provider is allowed to change the path.
    /// The async decoder runs only after this synchronous coordinated snapshot is complete.
    private func coordinatedRead<Value>(_ source: URL, accessor: (URL) throws -> Value) throws -> Value {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Value, Error>?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try accessor(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LibraryImportError.accessDenied }
        return try result.get()
    }

    private func importGroup(
        _ group: [ImportCandidate],
        originalURLs: [URL: URL],
        result: inout LibraryImportResult,
        cancellation: LibraryImportCancellation
    ) async throws -> (albumCount: Int, trackCount: Int, duplicate: String?, repairedTracks: Int) {
        guard !group.isEmpty else { return (0, 0, nil, 0) }
        var playable: [ProbedCandidate] = []
        for candidate in group {
            try cancellation.check()
            guard case .playable(let media) = metadataProbe.probe(url: candidate.url) else {
                result.recordFailure(originalURLs[candidate.url] ?? candidate.url, stage: "could not decode audio")
                continue
            }
            let size = (try? candidate.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            playable.append(ProbedCandidate(candidate: candidate, media: media, byteCount: size))
        }
        guard !playable.isEmpty else { return (0, 0, nil, 0) }

        var fields = ImportGrouper.albumFields(
            for: playable.map(\.candidate),
            batchLabel: playable.first?.candidate.batchLabel ?? ""
        )
        if fields.genre == nil,
           let metadataEnricher,
           let enriched = try? await metadataEnricher.automaticGenre(for: fields.artist) {
            fields = ImportAlbumFields(title: fields.title, artist: fields.artist, year: fields.year, genre: enriched)
        }
        if let repaired = try repairAdoptedAlbumIfNeeded(fields: fields, playable: playable), repaired > 0 {
            return (0, 0, nil, repaired)
        }
        if try isDuplicate(fields: fields, trackCount: playable.count) {
            return (0, 0, fields.title, 0)
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
                result.recordFailure(originalURLs[item.candidate.url] ?? item.candidate.url, stage: "could not save the audio", error: error)
            }
        }
        guard !tracks.isEmpty else { return (0, 0, nil, 0) }

        let artworkKey = await artwork(for: playable.map(\.candidate), originalURLs: originalURLs, albumID: albumID)
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
            return (1, tracks.count, nil, 0)
        } catch {
            throw error
        }
    }

    private func artwork(for group: [ImportCandidate], originalURLs: [URL: URL], albumID: String) async -> String? {
        for candidate in group {
            if let tags = try? await tagReader.read(url: candidate.url, includeArtwork: true),
               let key = artworkProcessor.process(tags.artworkData, key: albumID) {
                return key
            }
        }
        let names = ["cover", "folder", "front", "album", "artwork"]
        let directories = Array(Set(group.map { (originalURLs[$0.url] ?? $0.url).deletingLastPathComponent().standardizedFileURL }))
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
                      let data = try? coordinatedRead(candidate, accessor: { try Data(contentsOf: $0) }),
                      let key = artworkProcessor.process(data, key: albumID) else { continue }
                return key
            }
        }
        return nil
    }

    private func isDuplicate(fields: ImportAlbumFields, trackCount: Int) throws -> Bool {
        try !matchingAlbums(fields: fields, trackCount: trackCount).isEmpty
    }

    private func matchingAlbums(
        fields: ImportAlbumFields,
        trackCount: Int,
        limit: Int = 2
    ) throws -> [CatalogAlbumSummary] {
        var offset = 0
        var matches: [CatalogAlbumSummary] = []
        while matches.count < limit {
            let page = try repository.albumPage(
                offset: offset,
                limit: CatalogDatabase.maximumPageSize,
                sort: .recentlyAdded
            )
            matches.append(contentsOf: page.filter {
                ImportGrouper.isDuplicate(
                    existingTitle: $0.title,
                    existingArtist: $0.artist,
                    existingTrackCount: $0.trackCount,
                    candidate: fields,
                    candidateTrackCount: trackCount
                )
            })
            if page.count < CatalogDatabase.maximumPageSize { break }
            offset += page.count
        }
        return Array(matches.prefix(limit))
    }

    /// Re-link an already-adopted album after the collector moves its folder inside
    /// Documents/Music. This is deliberately conservative: exactly one matching album,
    /// all of its tracks must already be collector-owned Documents/Music references,
    /// and every candidate must match by disc/track number or normalized title.
    private func repairAdoptedAlbumIfNeeded(
        fields: ImportAlbumFields,
        playable: [ProbedCandidate]
    ) throws -> Int? {
        let newReferences = playable.compactMap { mediaStore.adoptedDocumentReference(for: $0.candidate.url) }
        guard newReferences.count == playable.count else { return nil }
        let matches = try matchingAlbums(fields: fields, trackCount: playable.count)
        guard matches.count == 1 else { return nil }

        let albumID = matches[0].id
        let existing = try repository.tracks(albumID: albumID)
        guard existing.count == playable.count else { return nil }
        guard existing.allSatisfy({ track in
            guard case .documents(let path) = track.mediaReference,
                  path.hasPrefix("Music/"),
                  !path.hasPrefix("Music/_Imported/"),
                  !path.hasPrefix("Music/_Migrated/"),
                  !path.hasPrefix("Music/_Restored/") else { return false }
            return true
        }) else { return nil }

        guard existing.indices.allSatisfy({
            adoptedTrackIdentityMatches(existing[$0], playable[$0].candidate)
        }) else { return nil }

        var changed = 0
        for index in existing.indices {
            if existing[index].mediaReference == newReferences[index] { continue }
            let item = playable[index]
            let updated = CatalogTrack(
                id: existing[index].id,
                albumID: existing[index].albumID,
                sequence: existing[index].sequence,
                discNumber: existing[index].discNumber,
                trackNumber: existing[index].trackNumber,
                title: existing[index].title,
                artist: existing[index].artist,
                duration: item.media.descriptor.duration,
                byteCount: item.byteCount,
                mediaReference: newReferences[index],
                importedAt: existing[index].importedAt
            )
            try repository.updateTrack(updated)
            changed += 1
        }
        return changed
    }

    private func adoptedTrackIdentityMatches(_ existing: CatalogTrack, _ candidate: ImportCandidate) -> Bool {
        let inferred = ImportGrouper.trackNumbers(from: candidate.url.lastPathComponent)
        let candidateDisc = candidate.tags.discNumber ?? inferred.disc
        let candidateTrack = candidate.tags.trackNumber ?? inferred.track
        if let existingTrack = existing.trackNumber, let candidateTrack,
           existingTrack == candidateTrack,
           (existing.discNumber ?? 1) == (candidateDisc ?? 1) {
            return true
        }
        let candidateTitle = clean(candidate.tags.title) ?? candidate.url.deletingPathExtension().lastPathComponent
        return ImportGrouper.normalizedPerson(existing.title) == ImportGrouper.normalizedPerson(candidateTitle)
    }

    private func classifyAdoptedFiles(
        _ files: [CollectedAudioFile],
        against index: AdoptedImportIndex
    ) -> AdoptionPlan {
        var plan = AdoptionPlan()
        var unused: [String: AdoptedImportIndex.Entry] = [:]
        for entry in index.entries { unused[entry.relativePath] = entry }
        for file in files {
            guard let path = file.relativePath else { plan.new.append(file); continue }
            if let prior = unused.removeValue(forKey: path) {
                if file.fileSize == prior.fileSize,
                   timestampsMatch(file.modificationTime, prior.modificationTime) {
                    plan.unchanged.append((file, prior))
                } else {
                    plan.modified.append((file, prior))
                }
                continue
            }
            let fallbackMatches = unused.values.filter {
                $0.fileSize == file.fileSize && timestampsMatch($0.modificationTime, file.modificationTime)
            }
            if let identifier = file.resourceIdentifier,
               let match = unused.values.first(where: { $0.resourceIdentifier == identifier }) {
                unused.removeValue(forKey: match.relativePath)
                plan.moved.append((file, match))
            } else if fallbackMatches.count == 1, let match = fallbackMatches.first {
                unused.removeValue(forKey: match.relativePath)
                plan.moved.append((file, match))
            } else {
                plan.new.append(file)
            }
        }
        plan.missing = Array(unused.values)
        return plan
    }

    private func bootstrapAdoptedIndex(from files: [CollectedAudioFile]) throws -> AdoptedImportIndex {
        let tracks = try adoptedTracksByRelativePath()
        return AdoptedImportIndex(entries: files.compactMap { file in
            guard let path = file.relativePath, let track = tracks[path] else { return nil }
            return indexEntry(file: file, track: track, missing: false)
        })
    }

    private func persistAdoptedIndex(
        files: [CollectedAudioFile],
        previous: AdoptedImportIndex?
    ) throws {
        let tracks = try adoptedTracksByRelativePath()
        var previousByPath: [String: AdoptedImportIndex.Entry] = [:]
        for entry in previous?.entries ?? [] { previousByPath[entry.relativePath] = entry }
        let currentPaths = Set(files.compactMap(\.relativePath))
        let currentIdentifiers = Set(files.compactMap(\.resourceIdentifier))
        let currentFingerprintCounts = Dictionary(grouping: files) { fileFingerprint($0) }.mapValues(\.count)
        var entries = files.compactMap { file -> AdoptedImportIndex.Entry? in
            guard let path = file.relativePath else { return nil }
            if let track = tracks[path] { return indexEntry(file: file, track: track, missing: false) }
            guard var prior = previousByPath[path] else { return nil }
            prior.fileSize = file.fileSize
            prior.modificationTime = file.modificationTime
            prior.resourceIdentifier = file.resourceIdentifier
            prior.missing = false
            return prior
        }
        entries.append(contentsOf: (previous?.entries ?? []).filter {
            !currentPaths.contains($0.relativePath)
                && ($0.resourceIdentifier == nil || !currentIdentifiers.contains($0.resourceIdentifier!))
                && currentFingerprintCounts[indexFingerprint($0), default: 0] != 1
        }.map {
            var missing = $0
            missing.missing = true
            return missing
        })
        entries.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        try repository.setSetting(AdoptedImportIndex(entries: entries), forKey: Self.adoptedIndexKey, at: now())
    }

    private func adoptedTracksByRelativePath() throws -> [String: CatalogTrack] {
        var result: [String: CatalogTrack] = [:]
        var offset = 0
        while true {
            let albums = try repository.albumPage(offset: offset, limit: CatalogDatabase.maximumPageSize, sort: .recentlyAdded)
            for album in albums {
                for track in try repository.tracks(albumID: album.id) {
                    guard case .documents(let path) = track.mediaReference,
                          path.hasPrefix("Music/"),
                          !path.hasPrefix("Music/_Imported/"),
                          !path.hasPrefix("Music/_Migrated/"),
                          !path.hasPrefix("Music/_Restored/") else { continue }
                    result[String(path.dropFirst("Music/".count))] = track
                }
            }
            if albums.count < CatalogDatabase.maximumPageSize { break }
            offset += albums.count
        }
        return result
    }

    private func indexEntry(file: CollectedAudioFile, track: CatalogTrack, missing: Bool) -> AdoptedImportIndex.Entry {
        AdoptedImportIndex.Entry(
            relativePath: file.relativePath ?? "",
            fileSize: file.fileSize,
            modificationTime: file.modificationTime,
            resourceIdentifier: file.resourceIdentifier,
            trackID: track.id,
            albumID: track.albumID,
            missing: missing
        )
    }

    private func relinkAdoptedTrack(_ entry: AdoptedImportIndex.Entry, to file: CollectedAudioFile) throws -> Bool {
        guard let trackID = entry.trackID,
              let track = try repository.track(id: trackID),
              let reference = mediaStore.adoptedDocumentReference(for: file.url) else { return false }
        try repository.updateTrack(CatalogTrack(
            id: track.id, albumID: track.albumID, sequence: track.sequence,
            discNumber: track.discNumber, trackNumber: track.trackNumber,
            title: track.title, artist: track.artist, duration: track.duration,
            byteCount: file.fileSize, mediaReference: reference, importedAt: track.importedAt
        ))
        return true
    }

    private func refreshAdoptedTrack(
        _ entry: AdoptedImportIndex.Entry,
        from file: CollectedAudioFile,
        cancellation: LibraryImportCancellation
    ) async throws -> Bool {
        guard let trackID = entry.trackID,
              let track = try repository.track(id: trackID),
              let reference = mediaStore.adoptedDocumentReference(for: file.url) else { return false }
        try cancellation.check()
        try await materialize(file.url)
        let tags = try await tagReader.read(url: file.url, includeArtwork: false)
        guard case .playable(let media) = metadataProbe.probe(url: file.url) else { return false }
        let inferred = ImportGrouper.trackNumbers(from: file.url.lastPathComponent)
        try repository.updateTrack(CatalogTrack(
            id: track.id, albumID: track.albumID, sequence: track.sequence,
            discNumber: tags.discNumber ?? inferred.disc ?? track.discNumber,
            trackNumber: tags.trackNumber ?? inferred.track ?? track.trackNumber,
            title: clean(tags.title) ?? track.title,
            artist: clean(tags.artist) ?? track.artist,
            duration: media.descriptor.duration,
            byteCount: file.fileSize,
            mediaReference: reference,
            importedAt: track.importedAt
        ))
        return true
    }

    private func timestampsMatch(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.some(let lhs), .some(let rhs)): return abs(lhs - rhs) < 0.001
        default: return false
        }
    }

    private func fileFingerprint(_ file: CollectedAudioFile) -> String {
        "\(file.fileSize):\(file.modificationTime ?? -1)"
    }

    private func indexFingerprint(_ entry: AdoptedImportIndex.Entry) -> String {
        "\(entry.fileSize):\(entry.modificationTime ?? -1)"
    }

    private func collectAudioFiles(
        _ selectedURLs: [URL],
        scanPolicy: ScanPolicy,
        cancellation: LibraryImportCancellation
    ) throws -> [CollectedAudioFile] {
        var collected: [CollectedAudioFile] = []
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
                        if isDirectory, scanPolicy == .adoptedMusicRoot,
                           isManagedMusicDirectory(entry) {
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
                let resolvedLabel = values?.isDirectory == true
                    ? target.deletingLastPathComponent().lastPathComponent
                    : batchLabel
                guard seen.insert(key).inserted else { continue }
                let metadata = try? target.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey
                ])
                collected.append(CollectedAudioFile(
                    url: target,
                    batchLabel: resolvedLabel,
                    relativePath: scanPolicy == .adoptedMusicRoot ? adoptedRelativePath(for: target) : nil,
                    fileSize: Int64(metadata?.fileSize ?? 0),
                    modificationTime: metadata?.contentModificationDate?.timeIntervalSince1970,
                    resourceIdentifier: resourceIdentifier(metadata?.fileResourceIdentifier)
                ))
            }
        }
        return collected.sorted {
            $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending
        }
    }

    private func adoptedRelativePath(for url: URL) -> String? {
        let root = mediaStore.documentsMusicRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    private func resourceIdentifier(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let data = value as? Data { return data.base64EncodedString() }
        return String(describing: value)
    }

    private func isManagedMusicDirectory(_ url: URL) -> Bool {
        let music = mediaStore.documentsMusicRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent() == music else { return false }
        return ["_Imported", "_Migrated", "_Restored"].contains(candidate.lastPathComponent)
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
        if values?.ubiquitousItemDownloadingStatus == .current { return }

        // `resourceValues` succeeds even for a path that does not exist, handing back a
        // record with every field nil, so whether it returned a value proves nothing.
        // Ask the file system instead: something worth waiting for is either flagged
        // ubiquitous, or absent with a ".icloud" placeholder standing in its place.
        let isUbiquitous = values?.isUbiquitousItem == true
        let hasPlaceholder = fileManager.fileExists(atPath: ubiquitousPlaceholderURL(for: url).path)
        if !isUbiquitous, fileManager.fileExists(atPath: url.path) { return }
        guard isUbiquitous || hasPlaceholder else { return }

        try? fileManager.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(downloadTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
            let refreshed = try? url.resourceValues(forKeys: keys)
            if refreshed?.ubiquitousItemDownloadingStatus == .current { return }
            // The placeholder was replaced by the real file.
            if refreshed?.isUbiquitousItem != true, fileManager.fileExists(atPath: url.path) { return }
        }
        throw LibraryImportError.sourceUnavailable
    }

    private func ubiquitousPlaceholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent)\(Self.ubiquitousPlaceholderSuffix)", isDirectory: false)
    }

    private static let ubiquitousPlaceholderSuffix = ".icloud"

    private func selectionSignature(
        files: [CollectedAudioFile],
        mode: LibraryImportGroupingMode
    ) -> String {
        var content = mode.rawValue + "\n"
        for entry in files {
            content += entry.url.standardizedFileURL.path
            content += "\u{0}\(entry.fileSize)\u{0}\(entry.modificationTime ?? -1)\n"
        }
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
