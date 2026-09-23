import XCTest
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
