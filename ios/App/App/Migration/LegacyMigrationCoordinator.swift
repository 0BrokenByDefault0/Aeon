import CryptoKit
import Foundation

enum LegacyMigrationCoordinatorError: Error, Equatable {
    case notPrepared
    case unknownArtifact
    case artifactMismatch
    case invalidChunk
    case checksumMismatch
    case byteCountMismatch
    case invalidCatalogue(String)
    case mediaValidationFailed
}

final class LegacyMigrationCoordinator: LegacyMigrationArtifactReceiving {
    static let publicationMarker = "migration.legacy.catalogue.published"
    static let maximumChunkBytes = 512 * 1_024

    var onProgress: ((LegacyMigrationProgress) -> Void)?
    let diagnosticsURL: URL

    private let repository: CatalogRepository
    private let artworkStore: ArtworkStore
    private let mediaStore: MediaStore
    private let metadataProbe: MetadataProbe
    private let fileManager: FileManager
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSRecursiveLock()

    private var snapshot: LegacyMigrationInventorySnapshot?
    private var descriptors: [String: LegacyMigrationBlobDescriptor] = [:]
    private var activeArtifacts: [String: LegacyMigrationArtifactStart] = [:]
    private var mappedImport: LegacyCatalogImport?
    private var isPublished = false

    private var runID: String? {
        snapshot.map { "\($0.inventory.databaseName):v\($0.inventory.schemaVersion)" }
    }

    init(
        repository: CatalogRepository,
        artworkStore: ArtworkStore,
        mediaStore: MediaStore,
        metadataProbe: MetadataProbe,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.artworkStore = artworkStore
        self.mediaStore = mediaStore
        self.metadataProbe = metadataProbe
        self.fileManager = fileManager
        self.now = now
        diagnosticsURL = repository.database.url.deletingLastPathComponent()
            .appendingPathComponent("legacy-migration-diagnostics.json", isDirectory: false)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func prepare(snapshot: LegacyMigrationInventorySnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        self.snapshot = snapshot
        descriptors = Dictionary(uniqueKeysWithValues: snapshot.blobs.map { ($0.artifactID, $0) })
        emit(phase: .staging, message: "Preparing the native catalogue")

        try repository.database.transaction {
            for store in LegacyMigrationStore.allCases {
                for record in snapshot.records[store, default: []] {
                    let idKey = store == .kv ? "k" : "id"
                    guard let sourceID = record[idKey]?.stringValue else {
                        throw LegacyMigrationCoordinatorError.invalidCatalogue("missing_\(store.rawValue)_id")
                    }
                    let stageStore = "\(runIdentifier(snapshot)):record:\(store.rawValue)"
                    if try repository.migrationRecord(sourceStore: stageStore, sourceID: sourceID) == nil {
                        try repository.stageMigrationRecord(MigrationStageRecord(
                            sourceStore: stageStore,
                            sourceID: sourceID,
                            status: .pending,
                            payload: try encoder.encode(record),
                            updatedAt: now()
                        ))
                    }
                }
            }
        }
        isPublished = (try repository.setting(Bool.self, forKey: Self.publicationMarker)) == true
        mappedImport = try map(snapshot)
        try publishIfReady()
        emitCurrentProgress()
    }

    func begin(artifact: LegacyMigrationArtifactStart) throws -> LegacyMigrationArtifactResume {
        lock.lock()
        defer { lock.unlock() }
        guard let runID, artifact.runID == runID else { throw LegacyMigrationCoordinatorError.notPrepared }
        guard let descriptor = descriptors[artifact.artifactID] else {
            throw LegacyMigrationCoordinatorError.unknownArtifact
        }
        guard artifact.ownerID == descriptor.ownerID, artifact.kind == descriptor.kind,
              artifact.byteLength == descriptor.byteLength, artifact.mediaType == descriptor.mediaType,
              artifact.fileName == descriptor.fileName else {
            throw LegacyMigrationCoordinatorError.artifactMismatch
        }
        if let complete = try artifactStage(for: artifact.artifactID), complete.wholeCRC32 != nil {
            return LegacyMigrationArtifactResume(
                nextOffset: complete.receivedBytes,
                nextSequence: complete.nextSequence,
                complete: true
            )
        }

        let partial = try mediaStore.migrationPartialURL(artifactKey: artifactKey(artifact.artifactID))
        let saved = try artifactStage(for: artifact.artifactID)
        var offset = saved?.receivedBytes ?? 0
        var sequence = saved?.nextSequence ?? 0
        let diskBytes = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if diskBytes != offset || offset > artifact.byteLength {
            if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
            offset = 0
            sequence = 0
        }
        if !fileManager.fileExists(atPath: partial.path) {
            guard fileManager.createFile(atPath: partial.path, contents: nil) else {
                throw LegacyMigrationCoordinatorError.invalidChunk
            }
        }
        let state = LegacyArtifactStage(
            artifactID: artifact.artifactID,
            receivedBytes: offset,
            nextSequence: sequence,
            expectedBytes: artifact.byteLength,
            wholeCRC32: nil,
            storedReference: nil
        )
        try stage(artifact: state, status: .materializing)
        activeArtifacts[artifact.artifactID] = artifact
        emitCurrentProgress()
        return LegacyMigrationArtifactResume(nextOffset: offset, nextSequence: sequence, complete: false)
    }

    func receive(chunk: LegacyMigrationArtifactChunk) throws -> LegacyMigrationArtifactResume {
        lock.lock()
        defer { lock.unlock() }
        guard let runID, chunk.runID == runID,
              let artifact = activeArtifacts[chunk.artifactID],
              let data = Data(base64Encoded: chunk.bytesBase64),
              !data.isEmpty, data.count <= Self.maximumChunkBytes,
              LegacyCRC32.checksum(data) == chunk.crc32,
              let current = try artifactStage(for: chunk.artifactID),
              chunk.offset == current.receivedBytes,
              chunk.sequence == current.nextSequence,
              chunk.offset + data.count <= artifact.byteLength else {
            throw LegacyMigrationCoordinatorError.invalidChunk
        }
        let partial = try mediaStore.migrationPartialURL(artifactKey: artifactKey(chunk.artifactID))
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        let next = LegacyArtifactStage(
            artifactID: chunk.artifactID,
            receivedBytes: chunk.offset + data.count,
            nextSequence: chunk.sequence + 1,
            expectedBytes: artifact.byteLength,
            wholeCRC32: nil,
            storedReference: nil
        )
        try stage(artifact: next, status: .materializing)
        return LegacyMigrationArtifactResume(
            nextOffset: next.receivedBytes,
            nextSequence: next.nextSequence,
            complete: false
        )
    }

    func finish(artifact finish: LegacyMigrationArtifactFinish) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let runID, finish.runID == runID,
              let artifact = activeArtifacts[finish.artifactID],
              let current = try artifactStage(for: finish.artifactID) else {
            throw LegacyMigrationCoordinatorError.unknownArtifact
        }
        guard finish.byteLength == artifact.byteLength, current.receivedBytes == finish.byteLength else {
            throw LegacyMigrationCoordinatorError.byteCountMismatch
        }
        let partial = try mediaStore.migrationPartialURL(artifactKey: artifactKey(finish.artifactID))
        guard try LegacyCRC32.checksum(fileURL: partial) == finish.crc32 else {
            throw LegacyMigrationCoordinatorError.checksumMismatch
        }

        let storedReference: String
        var audioWasCommittedWithStage = false
        switch artifact.kind {
        case .artwork:
            let data = try Data(contentsOf: partial, options: [.mappedIfSafe])
            storedReference = try artworkStore.store(data, key: artworkKey(artifact.ownerID))
            try fileManager.removeItem(at: partial)
        case .audio:
            let reference = try mediaStore.commitMigratedAudio(
                partialURL: partial,
                trackID: artifactKey(artifact.ownerID),
                fileExtension: audioExtension(artifact),
                verifier: { [metadataProbe] url in
                    if case .playable = metadataProbe.probe(url: url) { return true }
                    return false
                }
            )
            guard case .documents(let path) = reference else {
                throw LegacyMigrationCoordinatorError.mediaValidationFailed
            }
            storedReference = path
            if isPublished, var track = try repository.track(id: artifact.ownerID) {
                track.mediaReference = reference
                let completed = completedStage(
                    artifactID: finish.artifactID,
                    byteLength: finish.byteLength,
                    nextSequence: current.nextSequence,
                    crc32: finish.crc32,
                    storedReference: storedReference
                )
                try repository.completeLegacyAudioMigration(
                    track: track,
                    stage: migrationStageRecord(for: completed, status: .complete)
                )
                audioWasCommittedWithStage = true
            }
        }

        if !audioWasCommittedWithStage {
            try stage(artifact: completedStage(
                artifactID: finish.artifactID,
                byteLength: finish.byteLength,
                nextSequence: current.nextSequence,
                crc32: finish.crc32,
                storedReference: storedReference
            ), status: .complete)
        }
        activeArtifacts.removeValue(forKey: finish.artifactID)
        try publishIfReady()
        emitCurrentProgress()
    }

    func receive(failure: LegacyMigrationFailure) {
        lock.lock()
        defer { lock.unlock() }
        emit(phase: .failed, message: failure.message, completed: completedArtifactCount())
    }

    private func publishIfReady() throws {
        guard !isPublished, mappedImport != nil, let snapshot else { return }
        let artwork = descriptors.values.filter { $0.kind == .artwork }
        guard try artwork.allSatisfy({ try artifactStage(for: $0.artifactID)?.wholeCRC32 != nil }) else {
            return
        }
        emit(phase: .publishing, message: "Publishing the verified catalogue")
        let finalPayload = try map(snapshot)
        _ = try repository.publishLegacyImport(finalPayload, marker: Self.publicationMarker)
        isPublished = true
    }

    private func map(_ snapshot: LegacyMigrationInventorySnapshot) throws -> LegacyCatalogImport {
        let timestamp = now()
        let albumRows = snapshot.records[.albums, default: []]
        let trackRows = snapshot.records[.tracks, default: []]
        let artworkDescriptors = Set(snapshot.blobs.filter { $0.kind == .artwork }.map(\.ownerID))
        var usedSequences = Set<Int64>()
        var nextSequence = albumRows.compactMap { integer($0["seq"]) }.max() ?? 0
        var albums: [String: CatalogAlbum] = [:]
        var albumOrder: [String] = []
        for row in albumRows {
            guard let id = row["id"]?.stringValue else {
                throw LegacyMigrationCoordinatorError.invalidCatalogue("album_id")
            }
            var sequence = integer(row["seq"]) ?? 0
            if sequence <= 0 || usedSequences.contains(sequence) {
                repeat { nextSequence += 1 } while usedSequences.contains(nextSequence)
                sequence = nextSequence
            }
            usedSequences.insert(sequence)
            let artKey: String?
            if artworkDescriptors.contains(id) {
                artKey = try artifactStage(for: "artwork:\(id)")?.storedReference
            } else { artKey = nil }
            albums[id] = CatalogAlbum(
                id: id,
                sequence: sequence,
                title: nonempty(row["title"]?.stringValue) ?? "Untitled Transmission",
                artist: nonempty(row["artist"]?.stringValue) ?? "Unknown Artist",
                year: row["year"]?.stringValue ?? "",
                genre: row["genre"]?.stringValue ?? "",
                artworkKey: artKey,
                importedAt: timestamp,
                updatedAt: timestamp
            )
            albumOrder.append(id)
        }

        let blobTracks = Set(snapshot.blobs.filter { $0.kind == .audio }.map(\.ownerID))
        var tracksByAlbum: [String: [CatalogTrack]] = [:]
        var trackAlbums: [String: String] = [:]
        for row in trackRows {
            guard let id = row["id"]?.stringValue,
                  let albumID = row["albumId"]?.stringValue,
                  albums[albumID] != nil else {
                throw LegacyMigrationCoordinatorError.invalidCatalogue("track_reference")
            }
            let order = tracksByAlbum[albumID, default: []].count + 1
            let sequence = max(1, Int(integer(row["idx"]) ?? Int64(order)))
            guard !tracksByAlbum[albumID, default: []].contains(where: { $0.sequence == sequence }) else {
                throw LegacyMigrationCoordinatorError.invalidCatalogue("duplicate_track_sequence")
            }
            let mediaReference: MediaReference
            if let path = row["path"]?.stringValue {
                mediaReference = .documents(relativePath: path)
            } else if blobTracks.contains(id) {
                mediaReference = .legacyBlob(trackID: id)
            } else {
                mediaReference = .unavailable(trackID: id)
            }
            let descriptorBytes = snapshot.blobs.first { $0.kind == .audio && $0.ownerID == id }?.byteLength
            let bytes = max(0, integer(row["bytes"]) ?? Int64(descriptorBytes ?? 0))
            tracksByAlbum[albumID, default: []].append(CatalogTrack(
                id: id,
                albumID: albumID,
                sequence: sequence,
                discNumber: nil,
                trackNumber: sequence,
                title: nonempty(row["title"]?.stringValue) ?? "Untitled Track",
                artist: row["artist"]?.stringValue ?? "",
                duration: nil,
                byteCount: bytes,
                mediaReference: mediaReference,
                importedAt: timestamp
            ))
            trackAlbums[id] = albumID
        }
        let albumImports = try albumOrder.map { id -> (CatalogAlbum, [CatalogTrack]) in
            guard let album = albums[id] else { throw LegacyMigrationCoordinatorError.invalidCatalogue("album_order") }
            return (album, tracksByAlbum[id, default: []])
        }

        var playlists: [LegacyPlaylistImport] = []
        for row in snapshot.records[.playlists, default: []] {
            guard let id = row["id"]?.stringValue else {
                throw LegacyMigrationCoordinatorError.invalidCatalogue("playlist_id")
            }
            var trackIDs: [String] = []
            for case .object(let item) in row["items"]?.arrayValue ?? [] {
                guard let trackID = item["trackId"]?.stringValue,
                      let albumID = item["albumId"]?.stringValue,
                      trackAlbums[trackID] == albumID else {
                    throw LegacyMigrationCoordinatorError.invalidCatalogue("playlist_reference")
                }
                trackIDs.append(trackID)
            }
            playlists.append(LegacyPlaylistImport(
                playlist: CatalogPlaylist(
                    id: id,
                    name: nonempty(row["name"]?.stringValue) ?? "Untitled List",
                    createdAt: timestamp,
                    updatedAt: timestamp
                ),
                trackIDs: trackIDs
            ))
        }

        let kv: [String: LegacyJSONValue] = Dictionary(uniqueKeysWithValues: snapshot.records[.kv, default: []].compactMap { row -> (String, LegacyJSONValue)? in
            guard let key = row["k"]?.stringValue, let value = row["v"] else { return nil }
            return (key, value)
        })
        let plays = kv["plays"]?.objectValue ?? [:]
        let listening = plays.compactMap { key, value -> LegacyListeningImport? in
            guard trackAlbums[key] != nil, let count = integer(value), count >= 0 else { return nil }
            return LegacyListeningImport(trackID: key, playCount: count)
        }
        var settings: [String: Data] = [:]
        for (key, value) in kv {
            settings[settingKey(key)] = try encoder.encode(value)
        }
        return LegacyCatalogImport(albums: albumImports, playlists: playlists, listening: listening, settings: settings)
    }

    private func stage(artifact: LegacyArtifactStage, status: MigrationStageStatus) throws {
        try repository.stageMigrationRecord(migrationStageRecord(for: artifact, status: status))
    }

    private func migrationStageRecord(
        for artifact: LegacyArtifactStage,
        status: MigrationStageStatus
    ) throws -> MigrationStageRecord {
        MigrationStageRecord(
            sourceStore: "\(runID ?? "legacy"):artifact",
            sourceID: artifactKey(artifact.artifactID),
            status: status,
            payload: try encoder.encode(artifact),
            updatedAt: now()
        )
    }

    private func completedStage(
        artifactID: String,
        byteLength: Int,
        nextSequence: Int,
        crc32: UInt32,
        storedReference: String
    ) -> LegacyArtifactStage {
        LegacyArtifactStage(
            artifactID: artifactID,
            receivedBytes: byteLength,
            nextSequence: nextSequence,
            expectedBytes: byteLength,
            wholeCRC32: crc32,
            storedReference: storedReference
        )
    }

    private func artifactStage(for artifactID: String) throws -> LegacyArtifactStage? {
        guard let record = try repository.migrationRecord(
            sourceStore: "\(runID ?? "legacy"):artifact",
            sourceID: artifactKey(artifactID)
        ) else { return nil }
        return try decoder.decode(LegacyArtifactStage.self, from: record.payload)
    }

    private func emitCurrentProgress() {
        let completed = completedArtifactCount()
        let audioRemaining = descriptors.values.contains { descriptor in
            descriptor.kind == .audio && (try? artifactStage(for: descriptor.artifactID)?.wholeCRC32) == nil
        }
        let catalogLegacyRowsRemain = isPublished && ((try? repository.database.scalar(
            "SELECT COUNT(*) AS value FROM tracks WHERE media_kind = 'legacyBlob'"
        )?.int64) ?? 0) > 0
        let artRemaining = descriptors.values.contains { descriptor in
            descriptor.kind == .artwork && (try? artifactStage(for: descriptor.artifactID)?.wholeCRC32) == nil
        }
        let phase: LegacyMigrationPhase = !isPublished
            ? (artRemaining ? .artwork : .publishing)
            : ((audioRemaining || catalogLegacyRowsRemain) ? .audio : .complete)
        let message: String
        switch phase {
        case .artwork: message = "Preserving album artwork"
        case .publishing: message = "Publishing the native catalogue"
        case .audio: message = "Verifying embedded audio"
        case .complete: message = "Migration complete"
        case .staging: message = "Preparing the native catalogue"
        case .failed: message = "Migration needs attention"
        }
        emit(phase: phase, message: message, completed: completed)
    }

    private func completedArtifactCount() -> Int {
        descriptors.keys.reduce(into: 0) { count, id in
            if let stage = try? artifactStage(for: id), stage.wholeCRC32 != nil { count += 1 }
        }
    }

    private func emit(phase: LegacyMigrationPhase, message: String, completed: Int? = nil) {
        let progress = LegacyMigrationProgress(
            phase: phase,
            completedArtifacts: completed ?? 0,
            totalArtifacts: descriptors.count,
            catalogueReady: isPublished,
            sourceComplete: phase == .complete,
            message: message
        )
        let diagnostic: [String: LegacyJSONValue] = [
            "phase": .string(phase.rawValue),
            "message": .string(message),
            "completedArtifacts": .number(Double(progress.completedArtifacts)),
            "totalArtifacts": .number(Double(progress.totalArtifacts)),
            "catalogueReady": .bool(progress.catalogueReady),
            "sourceComplete": .bool(progress.sourceComplete),
            "updatedAt": .number(now().timeIntervalSince1970)
        ]
        try? encoder.encode(diagnostic).write(to: diagnosticsURL, options: .atomic)
        let completion = onProgress
        if Thread.isMainThread { completion?(progress) }
        else { DispatchQueue.main.async { completion?(progress) } }
    }

    private func artifactKey(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func runIdentifier(_ snapshot: LegacyMigrationInventorySnapshot) -> String {
        "\(snapshot.inventory.databaseName):v\(snapshot.inventory.schemaVersion)"
    }

    private func artworkKey(_ ownerID: String) -> String { "legacy-\(artifactKey(ownerID))" }

    private func settingKey(_ legacyKey: String) -> String {
        let direct = "legacy.kv.\(legacyKey)"
        return direct.utf8.count <= 128 ? direct : "legacy.kv.sha256.\(artifactKey(legacyKey))"
    }

    private func audioExtension(_ artifact: LegacyMigrationArtifactStart) -> String {
        let candidate = (artifact.fileName as NSString).pathExtension.lowercased()
        if !candidate.isEmpty, candidate.count <= 8,
           candidate.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) { return candidate }
        switch artifact.mediaType.lowercased() {
        case "audio/flac": return "flac"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        default: return "mp3"
        }
    }

    private func integer(_ value: LegacyJSONValue?) -> Int64? {
        guard let number = value?.numberValue, number.isFinite, number.rounded() == number,
              number >= Double(Int64.min), number < Double(Int64.max) else { return nil }
        return Int64(number)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
