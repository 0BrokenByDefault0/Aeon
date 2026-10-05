import Combine
import XCTest
@testable import App

@MainActor
final class PlaylistTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeonPlaylistTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    func testCreationDetailPlaybackDeleteAndReferentialCleanup() throws {
        let repository = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        let album = CatalogAlbum(
            id: "album", sequence: 1, title: "Glass Route", artist: "Arden Vale", year: "2026",
            genre: "Ambient", artworkKey: nil, importedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let tracks = [
            track(id: "first", albumID: album.id, sequence: 1, title: "First Light", media: .native(relativePath: "first.wav")),
            track(id: "missing", albumID: album.id, sequence: 2, title: "Missing Light", media: .unavailable(trackID: "missing")),
            track(id: "last", albumID: album.id, sequence: 3, title: "Last Light", media: .native(relativePath: "last.wav"))
        ]
        try repository.insertAlbum(album, tracks: tracks)
        let coordinator = PlaylistRecordingCoordinator()
        let playback = PlaybackController(coordinator: coordinator, playlistStore: repository)
        let controller = PlaylistsController(repository: repository, playback: playback)

        XCTAssertFalse(controller.create(name: "   "))
        XCTAssertTrue(controller.create(name: "  Night Routes  ", id: "route", at: Date(timeIntervalSince1970: 2)))
        try repository.replacePlaylistItems(playlistID: "route", trackIDs: ["last", "missing", "first"])
        controller.select(id: "route")

        XCTAssertEqual(controller.playlists.map(\.playlist.name), ["Night Routes"])
        XCTAssertEqual(controller.selectedItems.map(\.item.trackID), ["last", "missing", "first"])
        XCTAssertEqual(controller.selectedItems.map(\.unavailable), [false, true, false])
        controller.play(startingAt: 1)
        XCTAssertEqual(coordinator.loads.first?.trackID, "first")
        XCTAssertEqual(controller.message, "Route loaded. Missing tracks were skipped.")

        controller.remove(position: 1)
        controller.play(startingAt: 1)
        XCTAssertEqual(coordinator.loads.first?.trackID, "first")
        XCTAssertEqual(coordinator.loads.first?.queue.map(\.trackID), ["last", "first"])
        XCTAssertEqual(coordinator.loads.first?.index, 1)
        XCTAssertEqual(coordinator.playCount, 2)

        XCTAssertTrue(try repository.deleteAlbum(id: album.id))
        XCTAssertTrue(try repository.playlistItems(playlistID: "route").isEmpty)
        controller.select(id: "route")
        XCTAssertTrue(controller.selectedItems.isEmpty)
        XCTAssertTrue(controller.deleteSelected())
        XCTAssertTrue(try repository.playlists().isEmpty)
    }

    func testQueueConvertsToPlaylistWithoutMutatingItsStableOrder() throws {
        let repository = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        let coordinator = PlaylistRecordingCoordinator()
        let playback = PlaybackController(coordinator: coordinator, playlistStore: repository)
        let queue = ["past", "current", "next"].map {
            QueueItem(trackID: $0, albumID: "album", mediaRef: .native(relativePath: "\($0).wav"))
        }
        let album = CatalogAlbum(
            id: "album", sequence: 1, title: "Queue", artist: "Aeon", year: "2026", genre: "",
            artworkKey: nil, importedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
        )
        try repository.insertAlbum(album, tracks: queue.enumerated().map { index, item in
            track(id: item.trackID, albumID: album.id, sequence: index + 1, title: item.trackID, media: item.mediaRef)
        })
        playback.accept(snapshot: snapshot(queue: queue, index: 1))

        XCTAssertTrue(playback.saveQueueAsPlaylist(name: "  Full Route  ", id: "queue-route"))
        XCTAssertEqual(try repository.playlists().first?.name, "Full Route")
        XCTAssertEqual(try repository.playlistItems(playlistID: "queue-route").map(\.trackID), ["past", "current", "next"])
        XCTAssertTrue(coordinator.queueCalls.isEmpty)
    }

    func testRenameReorderAndFavouritesStayOutOfChartedRoutes() throws {
        let repository = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        try insertGlassRoute(into: repository)
        let playback = PlaybackController(coordinator: PlaylistRecordingCoordinator(), playlistStore: repository)
        let controller = PlaylistsController(repository: repository, playback: playback)

        XCTAssertTrue(controller.create(name: "Night", id: "route"))
        try repository.replacePlaylistItems(playlistID: "route", trackIDs: ["first", "second", "third"])
        controller.select(id: "route")
        XCTAssertFalse(controller.renameSelected(to: "   "))
        XCTAssertTrue(controller.renameSelected(to: "  Dawn  "))
        XCTAssertEqual(try repository.playlists().first?.name, "Dawn")
        XCTAssertEqual(controller.selectionTitle, "Dawn")

        controller.moveItems(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(try repository.playlistItems(playlistID: "route").map(\.trackID), ["third", "first", "second"])

        try repository.setFavourite(trackID: "second", true)
        try repository.setFavourite(trackID: "second", true)
        try repository.setFavourite(trackID: "first", true)
        XCTAssertTrue(try repository.isFavourite(trackID: "second"))
        XCTAssertFalse(try repository.isFavourite(trackID: "third"))
        // Observation reloads asynchronously; a fresh controller reads the catalogue now.
        let refreshed = PlaylistsController(repository: repository, playback: playback)
        XCTAssertEqual(refreshed.playlists.map(\.playlist.id), ["route"])
        XCTAssertEqual(refreshed.smartRoutes.map(\.route), [.favourites])
        XCTAssertEqual(refreshed.smartRoutes.first?.itemCount, 2)

        controller.select(smart: .favourites)
        XCTAssertFalse(controller.selectionIsEditable)
        XCTAssertFalse(controller.deleteSelected())
        XCTAssertFalse(controller.renameSelected(to: "Other"))
        XCTAssertEqual(controller.selectedItems.map(\.item.trackID), ["second", "first"])
        controller.remove(position: 0)
        XCTAssertFalse(try repository.isFavourite(trackID: "second"))
        XCTAssertEqual(controller.selectedItems.map(\.item.trackID), ["first"])
    }

    func testListeningRoutesOrderByRecencyAndCount() throws {
        let repository = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        try insertGlassRoute(into: repository)
        try repository.recordPlay(trackID: "first", at: Date(timeIntervalSince1970: 10))
        try repository.recordPlay(trackID: "first", at: Date(timeIntervalSince1970: 11))
        try repository.recordPlay(trackID: "third", at: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(try repository.listeningRouteItems(.recentlyPlayed).map(\.trackID), ["third", "first"])
        XCTAssertEqual(try repository.listeningRouteItems(.mostPlayed).map(\.trackID), ["first", "third"])
        let playback = PlaybackController(coordinator: PlaylistRecordingCoordinator(), playlistStore: repository)
        let controller = PlaylistsController(repository: repository, playback: playback)
        XCTAssertEqual(controller.smartRoutes.map(\.route), [.recentlyPlayed, .mostPlayed])
        XCTAssertTrue(controller.playlists.isEmpty)
    }

    func testM3URoundTripsAndImportResolvesByIDPathThenTitle() async throws {
        let repository = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        try insertGlassRoute(into: repository)
        let folder = root.appendingPathComponent("Documents/Playlists", isDirectory: true)
        let playback = PlaybackController(coordinator: PlaylistRecordingCoordinator(), playlistStore: repository)
        let controller = PlaylistsController(repository: repository, playback: playback, playlistsFolder: folder)

        XCTAssertTrue(controller.create(name: "Glass/Route", id: "route"))
        try repository.replacePlaylistItems(playlistID: "route", trackIDs: ["second", "first"])
        controller.select(id: "route")
        let exported = try XCTUnwrap(controller.exportSelected())
        XCTAssertEqual(exported.lastPathComponent, "Glass-Route.m3u8")
        let text = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("#EXTM3U\n#PLAYLIST:Glass/Route\n"))
        XCTAssertTrue(text.contains("#AEON-TRACK:second\n../Music/Arden Vale/Glass Route/02.flac"))

        let decoded = PlaylistM3U.decode(text)
        XCTAssertEqual(decoded.name, "Glass/Route")
        XCTAssertEqual(decoded.entries.map(\.trackID), ["second", "first"])
        XCTAssertEqual(decoded.entries.first?.documentsRelativePath, "Music/Arden Vale/Glass Route/02.flac")
        XCTAssertEqual(decoded.entries.first?.artist, "Arden Vale")
        XCTAssertEqual(decoded.entries.first?.title, "Second Light")

        // A file from another player: Windows separators, no Aeon IDs, one unknown track.
        let foreign = "\u{feff}#EXTM3U\r\n#EXTINF:61,Arden Vale - Third Light\r\nC:\\Music\\third.flac\r\n"
            + "..\\Music\\Arden Vale\\Glass Route\\02.flac\r\n#EXTINF:5,Nobody - Nothing\r\nnothing.mp3\r\n"
        try Data(foreign.utf8).write(to: folder.appendingPathComponent("Borrowed.m3u"))
        let imported = await controller.importPlaylistFiles()
        XCTAssertEqual(imported, 1)
        let borrowed = try XCTUnwrap(try repository.playlists().first { $0.name == "Borrowed" })
        XCTAssertEqual(try repository.playlistItems(playlistID: borrowed.id).map(\.trackID), ["third", "second"])
        // Re-running recognises both files by name and adds nothing.
        let repeated = await controller.importPlaylistFiles()
        XCTAssertEqual(repeated, 0)
        XCTAssertEqual(try repository.playlists().count, 2)

        XCTAssertNil(PlaylistM3U.documentsRelativePath(forLocation: "../../etc/passwd"))
        XCTAssertNil(PlaylistM3U.documentsRelativePath(forLocation: "https://example.com/a.mp3"))
        XCTAssertEqual(PlaylistM3U.documentsRelativePath(forLocation: "local.flac"), "Playlists/local.flac")
        XCTAssertEqual(PlaylistM3U.fileName(for: "..hidden"), "hidden.m3u8")
    }

    func testExportsPreserveExistingFilesAndDistinctSanitizedNames() throws {
        let repository = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        try insertGlassRoute(into: repository)
        let folder = root.appendingPathComponent("Documents/Playlists", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("Glass-Route.m3u8")
        let originalData = Data("collector-owned playlist".utf8)
        try originalData.write(to: original)
        let originalDate = Date(timeIntervalSince1970: 10)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: original.path)
        let occupiedDirectory = folder.appendingPathComponent("Glass-Route (2).m3u8")
        try FileManager.default.createDirectory(at: occupiedDirectory, withIntermediateDirectories: false)
        let playback = PlaybackController(coordinator: PlaylistRecordingCoordinator(), playlistStore: repository)
        let controller = PlaylistsController(repository: repository, playback: playback, playlistsFolder: folder)

        XCTAssertTrue(controller.create(name: "Glass/Route", id: "first-route"))
        try repository.replacePlaylistItems(playlistID: "first-route", trackIDs: ["second", "first"])
        controller.select(id: "first-route")
        let first = try XCTUnwrap(controller.exportSelected())
        XCTAssertEqual(first.lastPathComponent, "Glass-Route (3).m3u8")
        let firstData = try Data(contentsOf: first)
        XCTAssertTrue(controller.create(name: "Glass-Route", id: "second-route"))
        try repository.replacePlaylistItems(playlistID: "second-route", trackIDs: ["third"])
        controller.select(id: "second-route")
        let second = try XCTUnwrap(controller.exportSelected())
        XCTAssertEqual(second.lastPathComponent, "Glass-Route (4).m3u8")
        XCTAssertEqual(PlaylistM3U.decode(try String(contentsOf: second, encoding: .utf8)).entries.map(\.trackID), ["third"])
        controller.select(id: "first-route")
        let repeated = try XCTUnwrap(controller.exportSelected())
        XCTAssertEqual(repeated.lastPathComponent, "Glass-Route (5).m3u8")
        XCTAssertEqual(try Data(contentsOf: repeated), firstData)
        XCTAssertEqual(try Data(contentsOf: first), firstData)
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date, originalDate)
        XCTAssertTrue(try occupiedDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 5)
        let decoded = PlaylistM3U.decode(try String(contentsOf: first, encoding: .utf8))
        XCTAssertEqual(decoded.name, "Glass/Route")
        XCTAssertEqual(decoded.entries.map(\.trackID), ["second", "first"])
        XCTAssertEqual(decoded.entries.first?.title, "Second Light")
        XCTAssertEqual(decoded.entries.first?.artist, "Arden Vale")
        XCTAssertEqual(decoded.entries.first?.duration, 60)
        XCTAssertEqual(decoded.entries.first?.documentsRelativePath, "Music/Arden Vale/Glass Route/02.flac")
    }

    func testExportCollisionAtPublishTimeDoesNotReplaceTheOtherFile() throws {
        let repository = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        try insertGlassRoute(into: repository)
        let folder = root.appendingPathComponent("Documents/Playlists", isDirectory: true)
        let fileManager = PlaylistCollisionFileManager()
        let playback = PlaybackController(coordinator: PlaylistRecordingCoordinator(), playlistStore: repository)
        let controller = PlaylistsController(repository: repository, playback: playback, playlistsFolder: folder, fileManager: fileManager)
        XCTAssertTrue(controller.create(name: "Night", id: "route"))
        try repository.replacePlaylistItems(playlistID: "route", trackIDs: ["first"])
        controller.select(id: "route")

        let exported = try XCTUnwrap(controller.exportSelected())
        XCTAssertEqual(exported.lastPathComponent, "Night (2).m3u8")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Night.m3u8"), encoding: .utf8), "Concurrent file")
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    func testExportWaitsForOtherFileOperations() throws {
        let repository = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        try insertGlassRoute(into: repository)
        let folder = root.appendingPathComponent("Documents/Playlists", isDirectory: true)
        let playback = PlaybackController(coordinator: PlaylistRecordingCoordinator(), playlistStore: repository)
        let controller = PlaylistsController(repository: repository, playback: playback, playlistsFolder: folder)
        XCTAssertTrue(controller.create(name: "Night", id: "route"))
        try repository.replacePlaylistItems(playlistID: "route", trackIDs: ["first"])
        controller.select(id: "route")

        XCTAssertTrue(repository.beginFileOperation())
        XCTAssertNil(controller.exportSelected())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(controller.message, "Wait for other library operations to finish, then export again.")
        repository.endFileOperation()
        XCTAssertNotNil(controller.exportSelected())
    }

    func testSelectionRefreshesAfterExternalRenameAndDeletion() async throws {
        let repository = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        try insertGlassRoute(into: repository)
        let playback = PlaybackController(coordinator: PlaylistRecordingCoordinator(), playlistStore: repository)
        let controller = PlaylistsController(repository: repository, playback: playback)
        XCTAssertTrue(controller.create(name: "Night", id: "route"))
        try repository.replacePlaylistItems(playlistID: "route", trackIDs: ["first"])
        controller.select(id: "route")
        let renamed = expectation(description: "Open playlist reflects catalogue rename")
        let renameSubscription = controller.$selectedPlaylist.filter { $0?.name == "Dawn" }.first().sink { _ in renamed.fulfill() }
        defer { renameSubscription.cancel() }
        try repository.renamePlaylist(id: "route", name: "Dawn")
        await fulfillment(of: [renamed], timeout: 2)
        XCTAssertEqual(controller.selectionTitle, "Dawn")
        XCTAssertEqual(controller.selectedItems.map(\.item.trackID), ["first"])

        let deleted = expectation(description: "Deleted playlist clears selection")
        let deletionSubscription = controller.$selectedPlaylist.filter { $0 == nil }.first().sink { _ in deleted.fulfill() }
        defer { deletionSubscription.cancel() }
        XCTAssertTrue(try repository.deletePlaylist(id: "route"))
        await fulfillment(of: [deleted], timeout: 2)
        XCTAssertNil(controller.selectedPlaylist)
        XCTAssertTrue(controller.selectedItems.isEmpty)
        XCTAssertFalse(controller.selectionIsEditable)
    }

    func testSelectingUnknownPlaylistClearsPreviousItems() throws {
        let repository = CatalogRepository(database: try CatalogDatabase(rootURL: root))
        try insertGlassRoute(into: repository)
        let playback = PlaybackController(coordinator: PlaylistRecordingCoordinator(), playlistStore: repository)
        let controller = PlaylistsController(repository: repository, playback: playback)
        XCTAssertTrue(controller.create(name: "Night", id: "route"))
        try repository.replacePlaylistItems(playlistID: "route", trackIDs: ["first"])
        controller.select(id: "route")
        XCTAssertFalse(controller.selectedItems.isEmpty)
        controller.select(id: "does-not-exist")
        XCTAssertNil(controller.selectedPlaylist)
        XCTAssertTrue(controller.selectedItems.isEmpty)
    }

    private func insertGlassRoute(into repository: CatalogRepository) throws {
        let album = CatalogAlbum(
            id: "album", sequence: 1, title: "Glass Route", artist: "Arden Vale", year: "2026",
            genre: "Ambient", artworkKey: nil, importedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try repository.insertAlbum(album, tracks: [
            track(id: "first", albumID: album.id, sequence: 1, title: "First Light", media: .native(relativePath: "first.wav")),
            track(id: "second", albumID: album.id, sequence: 2, title: "Second Light",
                  media: .documents(relativePath: "Music/Arden Vale/Glass Route/02.flac")),
            track(id: "third", albumID: album.id, sequence: 3, title: "Third Light", media: .native(relativePath: "third.wav"))
        ])
    }

    private func track(id: String, albumID: String, sequence: Int, title: String, media: MediaReference) -> CatalogTrack {
        CatalogTrack(
            id: id, albumID: albumID, sequence: sequence, discNumber: 1, trackNumber: sequence,
            title: title, artist: "", duration: 60, byteCount: 32, mediaReference: media,
            importedAt: Date(timeIntervalSince1970: TimeInterval(sequence))
        )
    }

    private func snapshot(queue: [QueueItem], index: Int) -> PlaybackSnapshot {
        PlaybackSnapshot(
            version: 1, trackID: queue[index].trackID, queueRevision: 3, queue: queue, queueIndex: index,
            position: 0, intent: .paused, replayGainMode: .off, replayGainPreampDB: 0,
            masterVolume: 0.9, eqEnabled: false, eqBands: [], route: nil,
            sourceFormat: nil, outputFormat: nil, timestamp: Date(timeIntervalSince1970: 1)
        )
    }
}

private final class PlaylistCollisionFileManager: FileManager, @unchecked Sendable {
    private var insertedCollision = false

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if !insertedCollision {
            insertedCollision = true
            try Data("Concurrent file".utf8).write(to: dstURL, options: .withoutOverwriting)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class PlaylistRecordingCoordinator: PlaybackCoordinating {
    struct Load {
        let trackID: String
        let queue: [QueueItem]
        let index: Int
    }

    weak var delegate: PlaybackCoordinatorDelegate?
    private(set) var loads: [Load] = []
    private(set) var playCount = 0
    private(set) var queueCalls: [[QueueItem]] = []
    private var snapshot = PlaybackSnapshot(
        version: 0, trackID: nil, queueRevision: 0, queue: [], queueIndex: nil, position: 0,
        intent: .paused, replayGainMode: .off, replayGainPreampDB: 0, masterVolume: 0.9,
        eqEnabled: false, eqBands: [], route: nil, sourceFormat: nil, outputFormat: nil,
        timestamp: Date(timeIntervalSince1970: 1)
    )

    func initialize(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func load(trackID: String, mediaRef: MediaReference, queue: [QueueItem]?, index: Int?, completion: @escaping PlaybackCommandCompletion) {
        let queue = queue ?? [QueueItem(trackID: trackID, albumID: "", mediaRef: mediaRef)]
        let index = index ?? 0
        loads.append(Load(trackID: trackID, queue: queue, index: index))
        snapshot = replacing(queue: queue, index: index, intent: .paused)
        completion(.success(snapshot))
    }
    func play(completion: @escaping PlaybackCommandCompletion) {
        playCount += 1
        snapshot = replacing(queue: snapshot.queue, index: snapshot.queueIndex ?? 0, intent: .playing)
        completion(.success(snapshot))
    }
    func pause(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func toggle(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func seek(seconds: Double, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func next(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func previous(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func setQueue(items: [QueueItem], index: Int, revision: UInt64, completion: @escaping PlaybackCommandCompletion) {
        queueCalls.append(items)
        completion(.success(snapshot))
    }
    func setVolume(_ value: Float, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func setReplayGainMode(_ mode: ReplayGainMode, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func setReplayGainPreamp(_ db: Double, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func setEQ(enabled: Bool, bands: [EQBand], completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func setRepeatMode(_ mode: RepeatMode, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func getState(completion: @escaping (PlaybackSnapshot) -> Void) { completion(snapshot) }

    private func replacing(queue: [QueueItem], index: Int, intent: PlaybackIntent) -> PlaybackSnapshot {
        PlaybackSnapshot(
            version: snapshot.version + 1, trackID: queue.indices.contains(index) ? queue[index].trackID : nil,
            queueRevision: snapshot.queueRevision, queue: queue, queueIndex: queue.isEmpty ? nil : index,
            position: 0, intent: intent, replayGainMode: snapshot.replayGainMode,
            replayGainPreampDB: snapshot.replayGainPreampDB, masterVolume: snapshot.masterVolume,
            eqEnabled: snapshot.eqEnabled, eqBands: snapshot.eqBands, route: nil,
            sourceFormat: nil, outputFormat: nil, timestamp: Date()
        )
    }
}
