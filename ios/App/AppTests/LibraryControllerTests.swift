import XCTest
import UIKit
@testable import App

final class LibraryControllerTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    func testAllSortsAreStableAndMissingYearAndPlayedSortLast() throws {
        let repository = try makeRepository()
        try repository.insertAlbums([
            (album("z", sequence: 4, title: "Alpha", artist: "Same", year: ""), [track("tz", albumID: "z")]),
            (album("b", sequence: 2, title: "Beta", artist: "Able", year: "2020"), [track("tb", albumID: "b")]),
            (album("a", sequence: 1, title: "Beta", artist: "Able", year: "2020"), [track("ta", albumID: "a")]),
            (album("c", sequence: 3, title: "Gamma", artist: "Zed", year: "2018"), [track("tc", albumID: "c")])
        ])
        try repository.mergeListening(trackID: "ta", playCount: 2, lastPlayedAt: Date(timeIntervalSince1970: 20))
        try repository.mergeListening(trackID: "tc", playCount: 9, lastPlayedAt: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(try repository.albumPage(sort: .recentlyAdded).map(\.id), ["z", "c", "b", "a"])
        XCTAssertEqual(try repository.albumPage(sort: .artist).map(\.id), ["a", "b", "z", "c"])
        XCTAssertEqual(try repository.albumPage(sort: .title).map(\.id), ["z", "a", "b", "c"])
        XCTAssertEqual(try repository.albumPage(sort: .year).map(\.id), ["a", "b", "c", "z"])
        XCTAssertEqual(try repository.albumPage(sort: .mostPlayed).map(\.id), ["a", "c", "b", "z"])
        XCTAssertNil(try repository.albumPage(sort: .mostPlayed).last?.lastPlayedAt)
    }

    func testSearchReturnsAlbumsArtistsAndTracksInSeparateSections() throws {
        let repository = try makeRepository()
        try repository.insertAlbum(
            album("glass", sequence: 1, title: "Glass Archive", artist: "Björk", year: "2001"),
            tracks: [track("silver", albumID: "glass", title: "Silver Chamber", artist: "Guest Voice")]
        )

        XCTAssertEqual(try repository.search("archive").albums.map(\.id), ["glass"])
        XCTAssertEqual(try repository.search("BJORK").artists, ["Björk"])
        XCTAssertEqual(try repository.search("guest voice").artists, ["Guest Voice"])
        let trackResults = try repository.search("silver")
        XCTAssertTrue(trackResults.albums.isEmpty)
        XCTAssertTrue(trackResults.artists.isEmpty)
        XCTAssertEqual(trackResults.tracks.map(\.trackID), ["silver"])
    }

    func testSummaryPagingNeverLoadsAlbumTracks() throws {
        let repository = try makeRepository()
        try repository.insertAlbums((1...120).map { index in
            (album("album-\(index)", sequence: Int64(index)), [track("track-\(index)", albumID: "album-\(index)")])
        })

        let first = try repository.albumPage(limit: LibraryController.pageSize)
        let second = try repository.albumPage(offset: first.count, limit: LibraryController.pageSize)
        XCTAssertEqual(first.count, 48)
        XCTAssertEqual(second.count, 48)
        XCTAssertEqual(try repository.albumCount(), 120)
        XCTAssertEqual(first.first?.trackCount, 1)
        XCTAssertEqual(try repository.tracks(albumID: first[0].id).count, 1)
    }

    func testMovementPreviewIsReadOnlyAndConfirmedRechartCommitsMetadataWithCoordinates() throws {
        let repository = try makeRepository()
        try repository.insertAlbums([
            (album("one", sequence: 1, artist: "Shared", genre: "Soul"), [track("one-track", albumID: "one")]),
            (album("two", sequence: 2, artist: "Shared", genre: "Soul"), [track("two-track", albumID: "two")])
        ])
        let sky = SkyRepository(catalog: repository)
        let before = try sky.backfill()
        var draft = try XCTUnwrap(repository.album(id: "one"))
        draft.artist = "Moved Artist"
        draft.genre = "Ambient"

        XCTAssertEqual(try sky.affectedAlbumCount(for: draft), 2)
        XCTAssertEqual(try repository.album(id: "one")?.artist, "Shared")
        XCTAssertEqual(try sky.catalogue(), before)

        let after = try sky.rechart(updatedAlbum: draft)
        XCTAssertEqual(try repository.album(id: "one")?.artist, "Moved Artist")
        XCTAssertEqual(after.stars.first { $0.albumID == "one" }?.artistKey, "artist:moved-artist")
        XCTAssertNotEqual(
            before.stars.first { $0.albumID == "one" }?.coordinate,
            after.stars.first { $0.albumID == "one" }?.coordinate
        )
    }

    func testDeleteCommitsCataloguePlaylistAndSkyCleanupTogether() throws {
        let repository = try makeRepository()
        try repository.insertAlbum(album("album", sequence: 1), tracks: [track("track", albumID: "album")])
        try repository.createPlaylist(CatalogPlaylist(
            id: "playlist",
            name: "Set",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        ))
        try repository.replacePlaylistItems(playlistID: "playlist", trackIDs: ["track"])
        let sky = SkyRepository(catalog: repository)
        _ = try sky.backfill()

        XCTAssertTrue(try sky.deleteAlbum(id: "album"))
        XCTAssertNil(try repository.album(id: "album"))
        XCTAssertTrue(try repository.playlistItems(playlistID: "playlist").isEmpty)
        XCTAssertFalse(try sky.catalogue().stars.contains { $0.albumID == "album" })
    }

    func testManagedCleanupPreservesAdoptedDocuments() throws {
        let root = temporaryRoot(named: "Media")
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let store = try MediaStore(baseURL: root, documentsRoot: documents)
        let adopted = documents.appendingPathComponent("Music/Owned/track.flac")
        let imported = documents.appendingPathComponent("Music/_Imported/album/track.flac")
        try FileManager.default.createDirectory(at: adopted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imported.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("owned".utf8).write(to: adopted)
        try Data("copy".utf8).write(to: imported)

        try store.removeManagedMedia(.documents(relativePath: "Music/Owned/track.flac"))
        try store.removeManagedMedia(.documents(relativePath: "Music/_Imported/album/track.flac"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: adopted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
    }

    func testManagedCleanupRemovesRestoredCopiesButNotLookalikeCollectorFolders() throws {
        let root = temporaryRoot(named: "Restored")
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let store = try MediaStore(baseURL: root, documentsRoot: documents)
        let restored = documents.appendingPathComponent("Music/_Restored/operation/track.flac")
        let lookalike = documents.appendingPathComponent("Music/Artist/_Restored/track.flac")
        for url in [restored, lookalike] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(url.lastPathComponent.utf8).write(to: url)
        }

        try store.removeManagedMedia(.documents(relativePath: "Music/_Restored/operation/track.flac"))
        try store.removeManagedMedia(.documents(relativePath: "Music/Artist/_Restored/track.flac"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lookalike.path))
    }

    @MainActor
    func testSortAndDensityPersistAndUnknownChoicesUseDefaults() throws {
        let repository = try makeRepository()
        let original = try makeController(repository: repository)
        original.setSort(.artist)
        original.setDensity(.list)
        let restored = try makeController(repository: repository)
        XCTAssertEqual(restored.sort, .artist)
        XCTAssertEqual(restored.density, .list)

        try repository.setSetting("unknown", forKey: "library.sort.v1")
        try repository.setSetting("unknown", forKey: "library.density.v1")
        let fallback = try makeController(repository: repository)
        XCTAssertEqual(fallback.sort, .recent)
        XCTAssertEqual(fallback.density, .grid)
    }

    @MainActor
    func testMissingAndCorruptArtworkCanBeRetriedAfterRepair() async throws {
        let repository = try makeRepository()
        let controller = try makeController(repository: repository)
        let imageData = artworkData(color: .red)
        for key in ["missing.jpg", "corrupt.jpg"] {
            if key == "corrupt.jpg" {
                try Data("invalid image".utf8).write(to: controller.artworkStore.url(forKey: key))
            }
            controller.requestArtwork(key: key)
            try await waitForThumbnails(controller)
            XCTAssertNil(controller.thumbnails[key])

            try imageData.write(to: controller.artworkStore.url(forKey: key), options: .atomic)
            controller.requestArtwork(key: key)
            try await waitForThumbnails(controller)
            XCTAssertNotNil(controller.thumbnails[key], "A failed request must release its pending entry")
        }
    }

    @MainActor
    func testThumbnailRetentionIsBoundedAndEvictedArtworkLoadsAgain() async throws {
        let controller = try makeController(repository: makeRepository())
        let imageData = artworkData(color: .blue)
        for batch in 0..<4 {
            for index in 0..<LibraryController.pageSize {
                let key = "cover-\(batch * LibraryController.pageSize + index).jpg"
                try imageData.write(to: controller.artworkStore.url(forKey: key))
                controller.requestArtwork(key: key)
            }
            try await waitForThumbnails(controller)
            XCTAssertLessThanOrEqual(controller.thumbnails.count, LibraryController.thumbnailLimit)
        }
        XCTAssertEqual(controller.thumbnails.count, LibraryController.thumbnailLimit)
        XCTAssertNil(controller.thumbnails["cover-0.jpg"])
        controller.requestArtwork(key: "cover-0.jpg")
        try await waitForThumbnails(controller)
        XCTAssertNotNil(controller.thumbnails["cover-0.jpg"])
        XCTAssertEqual(controller.thumbnails.count, LibraryController.thumbnailLimit)
    }

    @MainActor
    func testMountedArtworkSurvivesPrefetchAndDuplicateVisibilityReferences() async throws {
        let controller = try makeController(repository: makeRepository())
        let imageData = artworkData(color: .red)
        try imageData.write(to: controller.artworkStore.url(forKey: "visible.jpg"))
        controller.retainVisibleArtwork(key: "visible.jpg")
        controller.retainVisibleArtwork(key: "visible.jpg")
        try await waitForThumbnails(controller)
        controller.releaseVisibleArtwork(key: "visible.jpg")
        for batch in 0..<4 {
            for index in 0..<LibraryController.pageSize {
                let key = "prefetch-\(batch * LibraryController.pageSize + index).jpg"
                try imageData.write(to: controller.artworkStore.url(forKey: key))
                controller.requestArtwork(key: key)
            }
            try await waitForThumbnails(controller)
            XCTAssertNotNil(controller.thumbnails["visible.jpg"], "Prefetch must preserve mounted shelf covers")
            XCTAssertLessThanOrEqual(controller.thumbnails.count, LibraryController.thumbnailLimit)
        }
        controller.releaseVisibleArtwork(key: "visible.jpg")
        try imageData.write(to: controller.artworkStore.url(forKey: "replacement.jpg"))
        controller.requestArtwork(key: "replacement.jpg")
        try await waitForThumbnails(controller)
        XCTAssertNil(controller.thumbnails["visible.jpg"], "The last disappearance must release the cover")
    }

    @MainActor
    func testQueuedThumbnailWorkDoesNotRetainTheController() throws {
        let repository = try makeRepository()
        var controller: LibraryController? = try makeController(repository: repository)
        weak var released = controller
        for index in 0..<500 { controller?.requestArtwork(key: "missing-\(index).jpg") }
        XCTAssertLessThanOrEqual(try XCTUnwrap(controller).pendingThumbnailCount, LibraryController.thumbnailLimit + 4)
        controller = nil
        XCTAssertNil(released, "Background decoding must not own the screen controller")
    }

    @MainActor
    func testSelectedLatePageArtworkRefreshesTheSameKeyAndSurvivesCacheChurn() async throws {
        let repository = try makeRepository()
        var original = album("one", sequence: 1)
        original.artworkKey = "album-one.jpg"
        try repository.insertAlbum(original, tracks: [track("track", albumID: "one")])
        try repository.insertAlbums((2...61).map { index in
            let id = "recent-\(index)"
            return (album(id, sequence: Int64(index)), [track("track-\(index)", albumID: id)])
        })
        let controller = try makeController(repository: repository)
        XCTAssertFalse(controller.albums.contains { $0.id == "one" })
        try artworkData(color: .red).write(to: controller.artworkStore.url(forKey: "album-one.jpg"))
        controller.selectAlbum(id: "one")
        try await waitForThumbnails(controller)
        let before = try XCTUnwrap(controller.thumbnails["album-one.jpg"]?.pngData())

        XCTAssertTrue(controller.saveAlbum(original, artworkData: artworkData(color: .blue, jpeg: true)))
        try await waitForThumbnails(controller)
        let after = try XCTUnwrap(controller.thumbnails["album-one.jpg"]?.pngData())
        XCTAssertNotEqual(after, before, "Replacing an image can reuse its key without reusing its pixels")
        XCTAssertEqual(try repository.album(id: "one")?.artworkKey, "album-one.jpg")
        XCTAssertEqual(controller.selectedAlbum?.id, "one")
        XCTAssertFalse(controller.albums.contains { $0.id == "one" })

        let imageData = artworkData(color: .green)
        for batch in 0..<4 {
            for index in 0..<LibraryController.pageSize {
                let key = "churn-\(batch * LibraryController.pageSize + index).jpg"
                try imageData.write(to: controller.artworkStore.url(forKey: key))
                controller.requestArtwork(key: key)
            }
            try await waitForThumbnails(controller)
            XCTAssertNotNil(controller.thumbnails["album-one.jpg"], "The open album's hero must remain available")
            XCTAssertLessThanOrEqual(controller.thumbnails.count, LibraryController.thumbnailLimit)
        }
    }

    @MainActor
    private func makeController(repository: CatalogRepository) throws -> LibraryController {
        let root = temporaryRoot(named: "Controller")
        let playback = PlaybackController(coordinator: PlaybackFixtureCoordinator(snapshot: nil))
        let sky = SkyRepository(catalog: repository)
        _ = try sky.backfill()
        return LibraryController(
            repository: repository,
            artworkStore: try ArtworkStore(rootURL: root.appendingPathComponent("Artwork")),
            mediaStore: try MediaStore(baseURL: root),
            playback: playback,
            skyRepository: sky,
            skyController: SkySceneController(repository: sky, catalog: repository, playback: playback),
            metadataEnricher: MetadataEnricher(repository: repository,
                musicBrainz: MusicBrainzGenreProvider(), apple: AppleGenreProvider())
        )
    }

    @MainActor
    private func artworkData(color: UIColor, jpeg: Bool = false) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let draw: (UIGraphicsImageRendererContext) -> Void = { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return jpeg ? renderer.jpegData(withCompressionQuality: 1, actions: draw) : renderer.pngData(actions: draw)
    }

    @MainActor
    private func waitForThumbnails(_ controller: LibraryController) async throws {
        let deadline = Date().addingTimeInterval(5)
        while controller.pendingThumbnailCount > 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.pendingThumbnailCount, 0, "Thumbnail requests did not drain")
    }

    private func makeRepository() throws -> CatalogRepository {
        CatalogRepository(database: try CatalogDatabase(rootURL: temporaryRoot(named: "Catalog")))
    }

    private func temporaryRoot(named name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeonLibraryControllerTests-\(name)", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        roots.append(root)
        return root
    }

    private func album(
        _ id: String,
        sequence: Int64,
        title: String = "Album",
        artist: String = "Artist",
        year: String = "2026",
        genre: String = "Electronic"
    ) -> CatalogAlbum {
        CatalogAlbum(
            id: id,
            sequence: sequence,
            title: title,
            artist: artist,
            year: year,
            genre: genre,
            artworkKey: nil,
            importedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(sequence))
        )
    }

    private func track(
        _ id: String,
        albumID: String,
        title: String = "Track",
        artist: String = ""
    ) -> CatalogTrack {
        CatalogTrack(
            id: id,
            albumID: albumID,
            sequence: 1,
            discNumber: 1,
            trackNumber: 1,
            title: title,
            artist: artist,
            duration: 180,
            byteCount: 0,
            mediaReference: .unavailable(trackID: id),
            importedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
