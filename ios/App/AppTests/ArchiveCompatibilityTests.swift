import XCTest
@testable import App

final class ArchiveCompatibilityTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    func testCatalogueAndZIP64BackupRoundTripPreserveMetadataOrderAndHigherPlayCount() throws {
        let source = try makeContext("source")
        let album = makeAlbum(id: "album", sequence: 1, title: "The Silver Chamber")
        let mediaURL = source.media.mediaURL(stableID: "track", fileExtension: "wav")
        try Data("native-audio-payload".utf8).write(to: mediaURL)
        let track = makeTrack(id: "track", albumID: album.id, sequence: 1, media: .native(relativePath: mediaURL.lastPathComponent))
        try source.repository.insertAlbum(album, tracks: [track])
        try source.repository.createPlaylist(CatalogPlaylist(
            id: "route", name: "Night Route", createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2)
        ))
        try source.repository.replacePlaylistItems(playlistID: "route", trackIDs: [track.id, track.id])
        try source.repository.mergeListening(
            trackID: track.id, playCount: 4, completedCount: 2, lastPosition: 11,
            lastPlayedAt: Date(timeIntervalSince1970: 20)
        )
        try source.repository.setSetting(true, forKey: MetadataEnricher.lookupEnabledKey)
        try source.repository.setSetting(UInt32(91), forKey: "sky.seed")
        try source.repository.upsertSkyRecord(SkyRecord(
            id: "star", kind: .star, sequence: 1, payload: Data("{\"albumID\":\"album\"}".utf8),
            updatedAt: Date(timeIntervalSince1970: 3)
        ))
        let checkpoint = makeSnapshot(track: track)

        let catalogueURL = source.roots.temporaryURL.appendingPathComponent("catalog.json")
        try source.writer.writeCatalogue(to: catalogueURL, playbackSnapshot: checkpoint, exportedAt: Date(timeIntervalSince1970: 30))
        let catalogue = try JSONDecoder().decode(AeonArchiveCatalog.self, from: Data(contentsOf: catalogueURL))
        XCTAssertEqual(catalogue.v, 3)
        XCTAssertEqual(catalogue.playlists.first?.trackIDs, ["track", "track"])
        XCTAssertEqual(catalogue.listening.first?.playCount, 4)
        XCTAssertEqual(catalogue.queueCheckpoint?.trackID, "track")
        XCTAssertEqual(catalogue.skySeed, 91)
        XCTAssertEqual(catalogue.skyRecords.map(\.id), ["star"])
        XCTAssertTrue(catalogue.albums.flatMap(\.tracks).allSatisfy { $0.audioPath == nil })
        XCTAssertTrue(catalogue.albums.allSatisfy { $0.artworkPath == nil })

        let backupURL = source.roots.temporaryURL.appendingPathComponent("backup.zip")
        var progressed = Set<String>()
        try source.writer.writeFullBackup(to: backupURL, playbackSnapshot: checkpoint) { progressed.insert($0.currentPath) }
        let backup = try ArchiveReader(url: backupURL)
        XCTAssertTrue(backup.entries.contains { $0.path == ArchiveWriter.catalogFilename && $0.method == 0 })
        XCTAssertTrue(backup.entries.contains { $0.path.hasPrefix("audio/") && $0.method == 0 })
        XCTAssertTrue(progressed.contains(ArchiveWriter.catalogFilename))

        let target = try makeContext("target")
        var existingAlbum = makeAlbum(id: "album", sequence: 7, title: "Older Title")
        existingAlbum.artworkKey = "existing.jpg"
        try target.repository.insertAlbum(
            existingAlbum,
            tracks: [
                makeTrack(id: "track", albumID: "album", sequence: 1, media: .unavailable(trackID: "track")),
                makeTrack(id: "obsolete", albumID: "album", sequence: 2, media: .unavailable(trackID: "obsolete"))
            ]
        )
        try target.repository.mergeListening(
            trackID: "track", playCount: 12, completedCount: 8, lastPosition: 1,
            lastPlayedAt: Date(timeIntervalSince1970: 10)
        )

        let result = try target.restorer.restore(from: backupURL)
        XCTAssertEqual(result, ArchiveRestoreResult(albumCount: 1, trackCount: 1, playlistCount: 1))
        XCTAssertEqual(try target.repository.album(id: "album")?.sequence, 7)
        XCTAssertEqual(try target.repository.album(id: "album")?.title, "The Silver Chamber")
        XCTAssertEqual(try target.repository.album(id: "album")?.artworkKey, "existing.jpg")
        XCTAssertNil(try target.repository.track(id: "obsolete"))
        XCTAssertEqual(try target.repository.playlistItems(playlistID: "route").map(\.trackID), ["track", "track"])
        XCTAssertEqual(try target.repository.listeningState(trackID: "track")?.playCount, 12)
        XCTAssertEqual(try target.repository.listeningState(trackID: "track")?.completedCount, 8)
        guard case .documents(let restoredPath) = try XCTUnwrap(target.repository.track(id: "track")).mediaReference else {
            return XCTFail("restored audio must use a Documents reference")
        }
        XCTAssertTrue(restoredPath.hasPrefix("Music/_Restored/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.roots.documentsURL.appendingPathComponent(restoredPath).path))
        XCTAssertEqual(target.state.load()?.trackID, "track")
    }

    func testLegacyV1AndV2RestoreAndInvalidBackupNeverChangeTheCatalogue() throws {
        for version in [1, 2] {
            let context = try makeContext("legacy-\(version)")
            let archiveURL = context.roots.temporaryURL.appendingPathComponent("legacy-\(version).zip")
            let catalog: [String: Any] = [
                "v": version,
                "exported": 42_000,
                "albums": [[
                    "id": "legacy-album-\(version)", "seq": 1, "title": "Legacy Sky", "artist": "Aeon",
                    "tracks": [["id": "legacy-track-\(version)", "idx": 1, "title": "Signal", "file": "audio/signal.mp3"]]
                ]],
                "playlists": [[
                    "id": "legacy-route-\(version)", "name": "Old Route",
                    "items": [["albumId": "legacy-album-\(version)", "trackId": "legacy-track-\(version)"]]
                ]],
                "plays": ["legacy-track-\(version)": 6],
                "settings": ["metadataLookups": true],
                "skySeed": 44
            ]
            try writeZIP32([
                (ArchiveWriter.catalogFilename, try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])),
                ("audio/signal.mp3", Data("legacy-audio".utf8))
            ], to: archiveURL)

            let result = try context.restorer.restore(from: archiveURL)
            XCTAssertEqual(result.albumCount, 1)
            XCTAssertEqual(try context.repository.playlistItems(playlistID: "legacy-route-\(version)").map(\.trackID), ["legacy-track-\(version)"])
            XCTAssertEqual(try context.repository.listeningState(trackID: "legacy-track-\(version)")?.playCount, 6)
            XCTAssertEqual(try context.repository.setting(Bool.self, forKey: MetadataEnricher.lookupEnabledKey), true)
            XCTAssertEqual(try context.repository.setting(UInt32.self, forKey: "sky.seed"), 44)
        }

        let target = try makeContext("invalid")
        try target.repository.insertAlbum(makeAlbum(id: "survivor", sequence: 1, title: "Survivor"), tracks: [])
        let invalidURL = target.roots.temporaryURL.appendingPathComponent("invalid.zip")
        let invalid: [String: Any] = [
            "v": 2,
            "albums": [[
                "id": "bad", "title": "Bad", "artist": "Bad",
                "tracks": [["id": "bad-track", "title": "Bad", "file": "audio/bad.mp3"]]
            ]],
            "playlists": [[
                "id": "broken", "name": "Broken",
                "items": [["albumId": "wrong", "trackId": "bad-track"]]
            ]]
        ]
        try writeZIP32([
            (ArchiveWriter.catalogFilename, try JSONSerialization.data(withJSONObject: invalid)),
            ("audio/bad.mp3", Data("bad".utf8))
        ], to: invalidURL)
        XCTAssertThrowsError(try target.restorer.restore(from: invalidURL))
        XCTAssertNotNil(try target.repository.album(id: "survivor"))
        XCTAssertNil(try target.repository.album(id: "bad"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.media.documentsMusicRoot.appendingPathComponent("_Restored").path))
    }

    func testReaderHandlesDeflateAndRejectsTraversalDuplicatesLimitsAndBadCRCWithoutPartials() throws {
        let root = temporaryRoot("reader")
        let deflatedURL = root.appendingPathComponent("deflated.zip")
        try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAIABh7LV2KTkaoGgAAABgAAAATAAAAZm9sZGVyL2RlZmxhdGVkLnR4dEtJTctJLElNUUgsSs7ILEtVKEiszMlPTAEAUEsBAhQDFAAAAAgAGHstXYpORqgaAAAAGAAAABMAAAAAAAAAAAAAAIABAAAAAGZvbGRlci9kZWZsYXRlZC50eHRQSwUGAAAAAAEAAQBBAAAASwAAAAAA")).write(to: deflatedURL)
        let output = root.appendingPathComponent("inflated", isDirectory: true)
        let deflated = try ArchiveReader(url: deflatedURL)
        let extracted = try deflated.extractAll(to: output)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(extracted["folder/deflated.txt"]), encoding: .utf8), "deflated archive payload")

        let unsafeURL = root.appendingPathComponent("unsafe.zip")
        try writeZIP32([("../escape", Data("x".utf8))], to: unsafeURL)
        XCTAssertThrowsError(try ArchiveReader(url: unsafeURL)) { XCTAssertEqual($0 as? ArchiveReaderError, .unsafePath("../escape")) }

        let duplicateURL = root.appendingPathComponent("duplicate.zip")
        try writeZIP32([("same", Data("one".utf8)), ("same", Data("two".utf8))], to: duplicateURL)
        XCTAssertThrowsError(try ArchiveReader(url: duplicateURL)) { XCTAssertEqual($0 as? ArchiveReaderError, .duplicatePath("same")) }

        let limitedURL = root.appendingPathComponent("limited.zip")
        try writeZIP32([("one", Data("1".utf8)), ("two", Data("2".utf8))], to: limitedURL)
        XCTAssertThrowsError(try ArchiveReader(url: limitedURL, limits: ArchiveReadLimits(maximumEntryCount: 1, maximumCentralDirectoryBytes: 1_024, maximumEntryBytes: 10, maximumTotalBytes: 10)))

        let corruptURL = root.appendingPathComponent("corrupt.zip")
        try writeZIP32([("payload", Data("sound".utf8))], to: corruptURL)
        var bytes = try Data(contentsOf: corruptURL)
        let nameLength = Int(bytes.le16ForTest(26))
        bytes[30 + nameLength] ^= 0xFF
        try bytes.write(to: corruptURL)
        let partialRoot = root.appendingPathComponent("partial", isDirectory: true)
        XCTAssertThrowsError(try ArchiveReader(url: corruptURL).extractAll(to: partialRoot)) { error in
            XCTAssertEqual(error as? ArchiveReaderError, .checksumFailed("payload"))
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(at: partialRoot, includingPropertiesForKeys: nil).count) ?? 0, 0)
    }

    private func makeContext(_ name: String) throws -> ArchiveTestContext {
        let root = temporaryRoot(name)
        return try ArchiveTestContext(root: root)
    }

    private func temporaryRoot(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeonArchiveCompatibilityTests-\(name)", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func makeAlbum(id: String, sequence: Int64, title: String) -> CatalogAlbum {
        CatalogAlbum(
            id: id, sequence: sequence, title: title, artist: "Arden Vale", year: "2026", genre: "Ambient",
            artworkKey: nil, importedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeTrack(id: String, albumID: String, sequence: Int, media: MediaReference) -> CatalogTrack {
        CatalogTrack(
            id: id, albumID: albumID, sequence: sequence, discNumber: 1, trackNumber: sequence,
            title: "Signal", artist: "", duration: 60, byteCount: 20, mediaReference: media,
            importedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeSnapshot(track: CatalogTrack) -> PlaybackSnapshot {
        let item = QueueItem(trackID: track.id, albumID: track.albumID, mediaRef: track.mediaReference)
        return PlaybackSnapshot(
            version: 3, trackID: track.id, queueRevision: 2, queue: [item], queueIndex: 0,
            position: 12, intent: .paused, replayGainMode: .track, replayGainPreampDB: -1,
            masterVolume: 0.8, eqEnabled: false, eqBands: [], route: nil,
            sourceFormat: nil, outputFormat: nil, timestamp: Date(timeIntervalSince1970: 4)
        )
    }

    private func writeZIP32(_ entries: [(String, Data)], to url: URL) throws {
        var data = Data()
        var central: [(name: Data, crc: UInt32, size: UInt32, offset: UInt32)] = []
        for (path, payload) in entries {
            let name = Data(path.utf8)
            let crc = CRC32.finish(CRC32.update(CRC32.initial, with: payload))
            let offset = UInt32(data.count)
            data.appendLE(UInt32(0x04034b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
            data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(crc); data.appendLE(UInt32(payload.count)); data.appendLE(UInt32(payload.count))
            data.appendLE(UInt16(name.count)); data.appendLE(UInt16(0)); data.append(name); data.append(payload)
            central.append((name, crc, UInt32(payload.count), offset))
        }
        let centralOffset = UInt32(data.count)
        for entry in central {
            data.appendLE(UInt32(0x02014b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
            data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(entry.crc); data.appendLE(entry.size); data.appendLE(entry.size)
            data.appendLE(UInt16(entry.name.count)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
            data.appendLE(UInt32(0)); data.appendLE(entry.offset); data.append(entry.name)
        }
        let centralSize = UInt32(data.count) - centralOffset
        data.appendLE(UInt32(0x06054b50)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(entries.count)); data.appendLE(UInt16(entries.count))
        data.appendLE(centralSize); data.appendLE(centralOffset); data.appendLE(UInt16(0))
        try data.write(to: url)
    }
}

private final class ArchiveTestContext {
    let roots: AppStorageRoots
    let repository: CatalogRepository
    let artwork: ArtworkStore
    let media: MediaStore
    let state: PlaybackStateStore
    let writer: ArchiveWriter
    let restorer: ArchiveRestorer

    init(root: URL) throws {
        roots = try AppStorageRoots.temporary(at: root, fileManager: .default)
        let support = roots.applicationSupportURL.appendingPathComponent("Aeon", isDirectory: true)
        repository = CatalogRepository(database: try CatalogDatabase(rootURL: support))
        artwork = try ArtworkStore(rootURL: support.appendingPathComponent("Artwork", isDirectory: true))
        media = try MediaStore(baseURL: roots.applicationSupportURL, documentsRoot: roots.documentsURL)
        state = PlaybackStateStore(baseURL: support.appendingPathComponent("State", isDirectory: true))
        writer = ArchiveWriter(repository: repository, artworkStore: artwork, mediaStore: media, temporaryRoot: roots.temporaryURL)
        restorer = ArchiveRestorer(
            repository: repository, artworkStore: artwork, mediaStore: media, playbackStateStore: state,
            restoreRoot: support.appendingPathComponent("Restore", isDirectory: true)
        )
    }
}

private extension Data {
    func le16ForTest(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
}
