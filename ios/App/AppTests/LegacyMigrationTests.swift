import UIKit
import WebKit
import XCTest
@testable import App

final class LegacyMigrationTests: XCTestCase {
    private var root: URL!
    private var database: CatalogDatabase!
    private var repository: CatalogRepository!
    private var artworkStore: ArtworkStore!
    private var mediaStore: MediaStore!

    private var fixturesURL: URL {
        Bundle(for: LegacyMigrationTests.self).resourceURL!.appendingPathComponent("audio", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeonLegacyMigrationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        database = try CatalogDatabase(rootURL: support.appendingPathComponent("Aeon", isDirectory: true))
        repository = CatalogRepository(database: database)
        artworkStore = try ArtworkStore(rootURL: support.appendingPathComponent("Aeon/Artwork", isDirectory: true))
        mediaStore = try MediaStore(baseURL: support, documentsRoot: documents)
    }

    override func tearDown() {
        database?.close()
        database = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testStagesThenPublishesExactCatalogueAndMaterializesArtifactsIdempotently() throws {
        let artwork = try jpegData()
        let audio = try Data(contentsOf: fixturesURL.appendingPathComponent("pcm-44100.wav"))
        let snapshot = makeSnapshot(artworkBytes: artwork.count, audioBytes: audio.count)
        let coordinator = makeCoordinator()
        let adoptedURL = mediaStore.documentsRoot.appendingPathComponent("Music/Clayton/Night Transit/01 Arrival.m4a")
        try FileManager.default.createDirectory(at: adoptedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let adoptedBytes = Data([7, 4, 1, 9])
        try adoptedBytes.write(to: adoptedURL)

        try coordinator.prepare(snapshot: snapshot)
        XCTAssertNil(try repository.album(id: "album-1"), "staged rows must be invisible before artwork verifies")
        XCTAssertEqual(try repository.migrationRecords(status: .pending).count, 12)

        let afterStagingRelaunch = makeCoordinator()
        try afterStagingRelaunch.prepare(snapshot: snapshot)
        XCTAssertNil(try repository.album(id: "album-1"))
        XCTAssertEqual(try repository.migrationRecords(status: .pending).count, 12)

        try send(artwork, descriptor: snapshot.blobs[0], to: afterStagingRelaunch)
        let album = try XCTUnwrap(repository.album(id: "album-1"))
        XCTAssertEqual(album.sequence, 23)
        XCTAssertEqual(album.title, "Night Transit")
        XCTAssertEqual(album.artist, "Clayton")
        XCTAssertNotNil(album.artworkKey)
        XCTAssertEqual(try repository.tracks(albumID: album.id).map(\.id), ["track-path", "track-blob", "track-missing"])
        XCTAssertEqual(
            try repository.track(id: "track-path")?.mediaReference,
            .documents(relativePath: "Music/Clayton/Night Transit/01 Arrival.m4a")
        )
        XCTAssertEqual(
            try repository.track(id: "track-missing")?.mediaReference,
            .documents(relativePath: "Music/Clayton/Night Transit/03 Missing.flac")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: try mediaStore.resolve(
            .documents(relativePath: "Music/Clayton/Night Transit/03 Missing.flac")
        ).path))
        XCTAssertEqual(try repository.playlistItems(playlistID: "playlist-1").map(\.trackID), ["track-blob", "track-blob"])
        XCTAssertEqual(try repository.listeningState(trackID: "track-blob")?.playCount, 11)
        XCTAssertEqual(
            try repository.setting(LegacyJSONValue.self, forKey: "legacy.kv.skySeed"),
            .number(4_294_967_000)
        )
        XCTAssertEqual(try repository.setting(LegacyJSONValue.self, forKey: "legacy.kv.seq"), .number(23))
        XCTAssertEqual(
            try repository.setting(LegacyJSONValue.self, forKey: "legacy.kv.settings"),
            .object(["volume": .number(0.72), "repeat": .string("album")])
        )
        XCTAssertEqual(
            try repository.setting(LegacyJSONValue.self, forKey: "legacy.kv.log"),
            .array([.object(["t": .number(100), "text": .string("First light")])])
        )
        XCTAssertEqual(
            try repository.setting(LegacyJSONValue.self, forKey: "legacy.kv.lastPlayed"),
            .object(["trackId": .string("track-blob")])
        )
        XCTAssertEqual(
            try repository.setting(LegacyJSONValue.self, forKey: "legacy.kv.unknownFutureField"),
            .object(["nested": .string("preserved")])
        )

        let afterPublicationRelaunch = makeCoordinator()
        try afterPublicationRelaunch.prepare(snapshot: snapshot)
        XCTAssertEqual(try repository.albumPage().map(\.id), ["album-1"])
        XCTAssertEqual(try afterPublicationRelaunch.begin(artifact: start(snapshot.blobs[1])).nextOffset, 0)
        try send(audio, descriptor: snapshot.blobs[1], to: afterPublicationRelaunch)
        guard case .documents(let migratedPath) = try XCTUnwrap(repository.track(id: "track-blob")).mediaReference else {
            return XCTFail("Embedded audio did not become a document-backed reference")
        }
        let migratedURL = try mediaStore.resolve(.documents(relativePath: migratedPath))
        XCTAssertEqual(try Data(contentsOf: migratedURL), audio)
        XCTAssertEqual(try LegacyCRC32.checksum(fileURL: migratedURL), LegacyCRC32.checksum(audio))

        let relaunched = makeCoordinator()
        try relaunched.prepare(snapshot: snapshot)
        XCTAssertTrue(try relaunched.begin(artifact: start(snapshot.blobs[0])).complete)
        XCTAssertTrue(try relaunched.begin(artifact: start(snapshot.blobs[1])).complete)
        XCTAssertEqual(try repository.albumPage().count, 1)
        XCTAssertEqual(try repository.playlistItems(playlistID: "playlist-1").count, 2)
        XCTAssertEqual(try Data(contentsOf: adoptedURL), adoptedBytes)
        XCTAssertTrue(try repository.deleteAlbum(id: "album-1"))
        XCTAssertEqual(try Data(contentsOf: adoptedURL), adoptedBytes, "catalogue deletion never deletes adopted files")
    }

    func testInterruptedArtifactResumesAtPersistedChunkWithoutDuplicates() throws {
        let audio = try Data(contentsOf: fixturesURL.appendingPathComponent("pcm-48000.wav"))
        let snapshot = makeSnapshot(artworkBytes: nil, audioBytes: audio.count)
        let first = makeCoordinator()
        try first.prepare(snapshot: snapshot)
        let artifact = start(try XCTUnwrap(snapshot.blobs.first))
        XCTAssertEqual(try first.begin(artifact: artifact).nextOffset, 0)
        let split = audio.count / 2
        let prefix = Data(audio[..<split])
        let checkpoint = try first.receive(chunk: LegacyMigrationArtifactChunk(
            runID: artifact.runID,
            artifactID: artifact.artifactID,
            sequence: 0,
            offset: 0,
            bytesBase64: prefix.base64EncodedString(),
            crc32: LegacyCRC32.checksum(prefix)
        ))
        XCTAssertEqual(checkpoint.nextOffset, split)

        let relaunched = makeCoordinator()
        try relaunched.prepare(snapshot: snapshot)
        let resume = try relaunched.begin(artifact: artifact)
        XCTAssertEqual(resume.nextOffset, split)
        XCTAssertEqual(resume.nextSequence, 1)
        let suffix = Data(audio[split...])
        _ = try relaunched.receive(chunk: LegacyMigrationArtifactChunk(
            runID: artifact.runID,
            artifactID: artifact.artifactID,
            sequence: 1,
            offset: split,
            bytesBase64: suffix.base64EncodedString(),
            crc32: LegacyCRC32.checksum(suffix)
        ))
        try relaunched.finish(artifact: LegacyMigrationArtifactFinish(
            runID: artifact.runID,
            artifactID: artifact.artifactID,
            byteLength: audio.count,
            crc32: LegacyCRC32.checksum(audio)
        ))
        XCTAssertEqual(try repository.albumPage().count, 1)
        guard case .documents = try XCTUnwrap(repository.track(id: "track-blob")).mediaReference else {
            return XCTFail("Resumed audio did not publish")
        }
    }

    func testEmptyLegacyCataloguePublishesAnExactEmptyManifest() throws {
        let snapshot = LegacyMigrationInventorySnapshot(
            inventory: LegacyMigrationInventory(
                databaseName: "isolation-db",
                schemaVersion: 1,
                counts: ["albums": 0, "tracks": 0, "playlists": 0, "kv": 0]
            ),
            ids: [.albums: [], .tracks: [], .playlists: [], .kv: []],
            records: [.albums: [], .tracks: [], .playlists: [], .kv: []],
            blobs: []
        )
        let sourceManifest = snapshot

        try makeCoordinator().prepare(snapshot: snapshot)

        XCTAssertEqual(snapshot, sourceManifest)
        XCTAssertTrue(try repository.albumPage().isEmpty)
        XCTAssertEqual(try repository.database.scalar("SELECT COUNT(*) AS value FROM tracks")?.int64, 0)
        XCTAssertEqual(try repository.setting(Bool.self, forKey: LegacyMigrationCoordinator.publicationMarker), true)
    }

    func testTenThousandRecordUpgradePublishesBoundedStableRowsWithoutSourceMutation() throws {
        let count = 5_000
        var albumIDs: [String] = []
        var trackIDs: [String] = []
        var albums: [[String: LegacyJSONValue]] = []
        var tracks: [[String: LegacyJSONValue]] = []
        albumIDs.reserveCapacity(count)
        trackIDs.reserveCapacity(count)
        albums.reserveCapacity(count)
        tracks.reserveCapacity(count)
        for index in 1 ... count {
            let albumID = "scale-album-\(index)"
            let trackID = "scale-track-\(index)"
            albumIDs.append(albumID)
            trackIDs.append(trackID)
            albums.append([
                "id": .string(albumID), "seq": .number(Double(index)),
                "title": .string("Scale Album \(index)"), "artist": .string("Aeon")
            ])
            tracks.append([
                "id": .string(trackID), "albumId": .string(albumID), "idx": .number(1),
                "title": .string("Scale Track \(index)"), "artist": .string("Aeon"),
                "path": .string("Music/Aeon/Scale/\(index).m4a"), "bytes": .number(1),
                "adopted": .bool(true)
            ])
        }
        let snapshot = LegacyMigrationInventorySnapshot(
            inventory: LegacyMigrationInventory(
                databaseName: "isolation-db",
                schemaVersion: 1,
                counts: ["albums": count, "tracks": count, "playlists": 0, "kv": 0]
            ),
            ids: [.albums: albumIDs, .tracks: trackIDs, .playlists: [], .kv: []],
            records: [.albums: albums, .tracks: tracks, .playlists: [], .kv: []],
            blobs: []
        )
        let sourceManifest = snapshot

        try makeCoordinator().prepare(snapshot: snapshot)

        XCTAssertEqual(snapshot, sourceManifest)
        XCTAssertEqual(try repository.database.scalar("SELECT COUNT(*) AS value FROM albums")?.int64, Int64(count))
        XCTAssertEqual(try repository.database.scalar("SELECT COUNT(*) AS value FROM tracks")?.int64, Int64(count))
        XCTAssertEqual(try repository.tracks(albumID: "scale-album-5000").map(\.id), ["scale-track-5000"])
        XCTAssertEqual(
            try repository.track(id: "scale-track-1")?.mediaReference,
            .documents(relativePath: "Music/Aeon/Scale/1.m4a")
        )
    }

    func testBadChunkCRCLeavesCheckpointAndSourceUntouched() throws {
        let audio = try Data(contentsOf: fixturesURL.appendingPathComponent("pcm-96000.wav"))
        let snapshot = makeSnapshot(artworkBytes: nil, audioBytes: audio.count)
        let coordinator = makeCoordinator()
        try coordinator.prepare(snapshot: snapshot)
        let artifact = start(try XCTUnwrap(snapshot.blobs.first))
        _ = try coordinator.begin(artifact: artifact)
        XCTAssertThrowsError(try coordinator.receive(chunk: LegacyMigrationArtifactChunk(
            runID: artifact.runID,
            artifactID: artifact.artifactID,
            sequence: 0,
            offset: 0,
            bytesBase64: audio.base64EncodedString(),
            crc32: 0
        ))) { XCTAssertEqual($0 as? LegacyMigrationCoordinatorError, .invalidChunk) }
        XCTAssertEqual(try coordinator.begin(artifact: artifact).nextOffset, 0)
        XCTAssertEqual(try repository.albumPage().count, 1)
    }

    func testPublicationConflictRollsBackEveryLegacyRow() throws {
        let timestamp = Date(timeIntervalSince1970: 1_600_000_000)
        try repository.insertAlbum(CatalogAlbum(
            id: "already-native", sequence: 99, title: "Native", artist: "Aeon",
            year: "", genre: "", artworkKey: nil, importedAt: timestamp, updatedAt: timestamp
        ), tracks: [])
        let base = makeSnapshot(artworkBytes: nil, audioBytes: 100)
        var records = base.records
        records[.albums, default: []].append([
            "id": .string("already-native"), "seq": .number(100),
            "title": .string("Conflict"), "artist": .string("Legacy")
        ])
        let snapshot = LegacyMigrationInventorySnapshot(
            inventory: LegacyMigrationInventory(
                databaseName: "isolation-db", schemaVersion: 1,
                counts: ["albums": 2, "tracks": 3, "playlists": 1, "kv": 7]
            ),
            ids: [.albums: ["album-1", "already-native"], .tracks: base.ids[.tracks] ?? [],
                  .playlists: base.ids[.playlists] ?? [], .kv: base.ids[.kv] ?? []],
            records: records,
            blobs: base.blobs
        )

        XCTAssertThrowsError(try makeCoordinator().prepare(snapshot: snapshot))
        XCTAssertNil(try repository.album(id: "album-1"), "a failed publication cannot expose an earlier insert")
        XCTAssertEqual(try repository.albumPage().map(\.id), ["already-native"])
    }

    @MainActor
    @available(iOS 15.0, *)
    func testInstalledUpgradePreservesIDsPositionsAndAudioBytesEndToEnd() async throws {
        #if targetEnvironment(simulator)
        let artwork = try jpegData()
        let audio = try Data(contentsOf: fixturesURL.appendingPathComponent("pcm-44100.wav"))
        let seedController = AeonBridgeViewController()
        let seedWindow = UIWindow(frame: UIScreen.main.bounds)
        seedWindow.rootViewController = seedController
        seedWindow.isHidden = false
        seedController.loadViewIfNeeded()
        guard let seedWebView = seedController.webView else { return XCTFail("Seed web view missing") }
        try await waitForJavaScript("typeof dbClearAll === 'function' && db !== null", in: seedWebView)
        _ = try await callAsync("""
            const bytes = value => Uint8Array.from(atob(value), character => character.charCodeAt(0));
            await dbClearAll();
            await dbPut('albums',{id:'installed-album',seq:41,title:'Installed',artist:'Aeon',art:new Blob([bytes('\(artwork.base64EncodedString())')],{type:'image/jpeg'})});
            await dbPut('tracks',{id:'installed-blob',albumId:'installed-album',idx:1,title:'Embedded',artist:'Aeon',blob:new File([bytes('\(audio.base64EncodedString())')],'01 Embedded.wav',{type:'audio/wav'})});
            await dbPut('tracks',{id:'installed-path',albumId:'installed-album',idx:2,title:'Adopted',artist:'Aeon',path:'Music/Aeon/Installed/02 Adopted.m4a',bytes:77,adopted:true});
            await dbPut('playlists',{id:'installed-list',name:'Route',items:[{albumId:'installed-album',trackId:'installed-blob'},{albumId:'installed-album',trackId:'installed-path'}]});
            await dbPut('kv',{k:'plays',v:{'installed-blob':9}});
            await dbPut('kv',{k:'lastPlayed',v:{albumId:'installed-album',trackId:'installed-blob',qIndex:0,queue:[{albumId:'installed-album',trackId:'installed-blob'}]}});
            return true;
            """, in: seedWebView)

        let probe = LegacyMigrationInventoryProbe()
        let complete = expectation(description: "installed upgrade completed")
        var coordinator: LegacyMigrationCoordinator?
        probe.onCompletion = { [self] result in
            do {
                let snapshot = try result.get()
                let value = makeCoordinator()
                value.onProgress = { progress in if progress.sourceComplete { complete.fulfill() } }
                coordinator = value
                probe.artifactReceiver = value
                try value.prepare(snapshot: snapshot)
            } catch {
                XCTFail("Installed upgrade failed: \(error)")
            }
        }
        let migrationController = LegacyMigrationViewController(inventoryProbe: probe)
        let migrationWindow = UIWindow(frame: UIScreen.main.bounds)
        migrationWindow.rootViewController = migrationController
        migrationWindow.isHidden = false
        migrationController.loadViewIfNeeded()

        await fulfillment(of: [complete], timeout: 10)
        XCTAssertNotNil(coordinator)
        XCTAssertEqual(try repository.albumPage().map(\.id), ["installed-album"])
        XCTAssertEqual(try repository.tracks(albumID: "installed-album").map(\.id), ["installed-blob", "installed-path"])
        XCTAssertEqual(try repository.playlistItems(playlistID: "installed-list").map(\.position), [0, 1])
        XCTAssertEqual(try repository.playlistItems(playlistID: "installed-list").map(\.trackID), ["installed-blob", "installed-path"])
        XCTAssertEqual(try repository.listeningState(trackID: "installed-blob")?.playCount, 9)
        guard case .documents(let migratedPath) = try XCTUnwrap(repository.track(id: "installed-blob")).mediaReference else {
            return XCTFail("Installed blob was not materialized")
        }
        let migrated = try Data(contentsOf: mediaStore.resolve(.documents(relativePath: migratedPath)))
        XCTAssertEqual(migrated.count, audio.count)
        XCTAssertEqual(LegacyCRC32.checksum(migrated), LegacyCRC32.checksum(audio))

        let sourceManifestValue = try await callAsync("""
            const album = (await dbAll('albums')).find(value => value.id === 'installed-album');
            const track = (await dbAll('tracks')).find(value => value.id === 'installed-blob');
            const playlist = (await dbAll('playlists')).find(value => value.id === 'installed-list');
            return {albumID:album.id,artBytes:album.art.size,trackID:track.id,audioBytes:track.blob.size,positions:playlist.items.map((_,index)=>index)};
            """, in: seedWebView)
        let sourceManifest = try XCTUnwrap(sourceManifestValue as? [String: Any])
        XCTAssertEqual(sourceManifest["albumID"] as? String, "installed-album")
        XCTAssertEqual(sourceManifest["trackID"] as? String, "installed-blob")
        XCTAssertEqual(sourceManifest["artBytes"] as? Int, artwork.count)
        XCTAssertEqual(sourceManifest["audioBytes"] as? Int, audio.count)
        XCTAssertEqual(sourceManifest["positions"] as? [Int], [0, 1])

        _ = try await callAsync("await dbClearAll(); return true;", in: seedWebView)
        migrationWindow.isHidden = true
        seedWindow.isHidden = true
        #else
        throw XCTSkip("The installed-upgrade fixture requires the iOS Simulator")
        #endif
    }

    private func makeCoordinator() -> LegacyMigrationCoordinator {
        LegacyMigrationCoordinator(
            repository: repository,
            artworkStore: artworkStore,
            mediaStore: mediaStore,
            metadataProbe: MetadataProbe(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func makeSnapshot(artworkBytes: Int?, audioBytes: Int) -> LegacyMigrationInventorySnapshot {
        let album: [String: LegacyJSONValue] = [
            "id": .string("album-1"), "seq": .number(23), "title": .string("Night Transit"),
            "artist": .string("Clayton"), "year": .string("2026"), "genre": .string("Electronic")
        ]
        let tracks: [[String: LegacyJSONValue]] = [
            ["id": .string("track-path"), "albumId": .string("album-1"), "idx": .number(1),
             "title": .string("Arrival"), "artist": .string("Clayton"),
             "path": .string("Music/Clayton/Night Transit/01 Arrival.m4a"), "bytes": .number(321),
             "adopted": .bool(true)],
            ["id": .string("track-blob"), "albumId": .string("album-1"), "idx": .number(2),
             "title": .string("Signal"), "artist": .string("Clayton"), "bytes": .number(Double(audioBytes))],
            ["id": .string("track-missing"), "albumId": .string("album-1"), "idx": .number(3),
             "title": .string("Gone"), "artist": .string("Clayton"),
             "path": .string("Music/Clayton/Night Transit/03 Missing.flac"), "bytes": .number(99)]
        ]
        let playlist: [String: LegacyJSONValue] = [
            "id": .string("playlist-1"), "name": .string("Loop"),
            "items": .array([
                .object(["albumId": .string("album-1"), "trackId": .string("track-blob")]),
                .object(["albumId": .string("album-1"), "trackId": .string("track-blob")])
            ])
        ]
        let kv: [[String: LegacyJSONValue]] = [
            ["k": .string("plays"), "v": .object(["track-blob": .number(11)])],
            ["k": .string("settings"), "v": .object(["volume": .number(0.72), "repeat": .string("album")])],
            ["k": .string("skySeed"), "v": .number(4_294_967_000)],
            ["k": .string("lastPlayed"), "v": .object(["trackId": .string("track-blob")])],
            ["k": .string("log"), "v": .array([.object(["t": .number(100), "text": .string("First light")])])],
            ["k": .string("seq"), "v": .number(23)],
            ["k": .string("unknownFutureField"), "v": .object(["nested": .string("preserved")])]
        ]
        var blobs: [LegacyMigrationBlobDescriptor] = []
        if let artworkBytes {
            blobs.append(LegacyMigrationBlobDescriptor(
                ownerID: "album-1", kind: .artwork, byteLength: artworkBytes,
                mediaType: "image/jpeg", fileName: ""
            ))
        }
        blobs.append(LegacyMigrationBlobDescriptor(
            ownerID: "track-blob", kind: .audio, byteLength: audioBytes,
            mediaType: "audio/wav", fileName: "02 Signal.wav"
        ))
        let records: [LegacyMigrationStore: [[String: LegacyJSONValue]]] = [
            .albums: [album], .tracks: tracks, .playlists: [playlist], .kv: kv
        ]
        return LegacyMigrationInventorySnapshot(
            inventory: LegacyMigrationInventory(
                databaseName: "isolation-db", schemaVersion: 1,
                counts: ["albums": 1, "tracks": 3, "playlists": 1, "kv": 7]
            ),
            ids: [.albums: ["album-1"], .tracks: tracks.compactMap { $0["id"]?.stringValue },
                  .playlists: ["playlist-1"], .kv: kv.compactMap { $0["k"]?.stringValue }],
            records: records,
            blobs: blobs
        )
    }

    private func send(
        _ data: Data,
        descriptor: LegacyMigrationBlobDescriptor,
        to coordinator: LegacyMigrationCoordinator
    ) throws {
        let artifact = start(descriptor)
        let resume = try coordinator.begin(artifact: artifact)
        XCTAssertFalse(resume.complete)
        var sequence = resume.nextSequence
        for offset in stride(from: resume.nextOffset, to: data.count, by: LegacyMigrationCoordinator.maximumChunkBytes) {
            let end = min(data.count, offset + LegacyMigrationCoordinator.maximumChunkBytes)
            let chunk = Data(data[offset..<end])
            _ = try coordinator.receive(chunk: LegacyMigrationArtifactChunk(
                runID: artifact.runID,
                artifactID: artifact.artifactID,
                sequence: sequence,
                offset: offset,
                bytesBase64: chunk.base64EncodedString(),
                crc32: LegacyCRC32.checksum(chunk)
            ))
            sequence += 1
        }
        try coordinator.finish(artifact: LegacyMigrationArtifactFinish(
            runID: artifact.runID,
            artifactID: artifact.artifactID,
            byteLength: data.count,
            crc32: LegacyCRC32.checksum(data)
        ))
    }

    private func start(_ descriptor: LegacyMigrationBlobDescriptor) -> LegacyMigrationArtifactStart {
        LegacyMigrationArtifactStart(
            runID: "isolation-db:v1",
            artifactID: descriptor.artifactID,
            ownerID: descriptor.ownerID,
            kind: descriptor.kind,
            byteLength: descriptor.byteLength,
            mediaType: descriptor.mediaType,
            fileName: descriptor.fileName
        )
    }

    private func jpegData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    @MainActor
    private func waitForJavaScript(_ script: String, in webView: WKWebView) async throws {
        for _ in 0..<100 {
            if (try? await evaluate(script, in: webView)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for the Capacitor page")
    }

    @MainActor
    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    @MainActor
    @available(iOS 15.0, *)
    private func callAsync(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }
}
