import XCTest
@testable import App

final class CatalogRepositoryTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    func testPreferencesSavedBeforeNewKeysKeepTheCollectorsChoices() throws {
        let stored = Data(#"{"oneImportOneAlbum":false,"metadataLookups":true,"hud":true,"highSkyContrast":false,"reduceMotion":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AeonPreferences.self, from: stored)
        XCTAssertFalse(decoded.oneImportOneAlbum)
        XCTAssertTrue(decoded.metadataLookups)
        XCTAssertTrue(decoded.hud)
        XCTAssertTrue(decoded.reduceMotion)
        XCTAssertFalse(decoded.matchSourceSampleRate)
        XCTAssertFalse(decoded.spotlightAlbums)

        var updated = decoded
        updated.spotlightAlbums = true
        let roundTrip = try JSONDecoder().decode(AeonPreferences.self, from: try JSONEncoder().encode(updated))
        XCTAssertEqual(roundTrip, updated)
    }

    func testAlbumOrderIsDeterministicAndTrackOrderIsNatural() throws {
        let repository = try makeRepository()
        try repository.insertAlbum(
            album(id: "later", sequence: 2, title: "B", artist: "Same"),
            tracks: [
                track(id: "unnumbered", albumID: "later", sequence: 1, number: nil),
                track(id: "track-10", albumID: "later", sequence: 2, number: 10),
                track(id: "track-2", albumID: "later", sequence: 3, number: 2),
                track(id: "disc-2", albumID: "later", sequence: 4, disc: 2, number: 1)
            ]
        )
        try repository.insertAlbum(album(id: "earlier", sequence: 1, title: "A", artist: "Same"), tracks: [])

        XCTAssertEqual(try repository.albumPage().map(\.id), ["later", "earlier"])
        XCTAssertEqual(try repository.albumPage(sort: .artist).map(\.id), ["earlier", "later"])
        XCTAssertEqual(
            try repository.tracks(albumID: "later").map(\.id),
            ["track-2", "track-10", "unnumbered", "disc-2"]
        )
        XCTAssertEqual(try repository.albumPage().first?.trackCount, 4)
    }

    func testDuplicateStableIDsRejectTheWholeBatch() throws {
        let repository = try makeRepository()
        XCTAssertThrowsError(try repository.insertAlbums([
            (album(id: "one", sequence: 1), [track(id: "same", albumID: "one", sequence: 1)]),
            (album(id: "two", sequence: 2), [track(id: "same", albumID: "two", sequence: 1)])
        ])) {
            XCTAssertEqual($0 as? CatalogRepositoryError, .duplicateStableID("same"))
        }
        XCTAssertTrue(try repository.albumPage().isEmpty)

        try repository.insertAlbum(album(id: "one", sequence: 1), tracks: [])
        XCTAssertThrowsError(try repository.insertAlbum(album(id: "one", sequence: 2), tracks: [])) {
            XCTAssertEqual($0 as? CatalogRepositoryError, .duplicateStableID("one"))
        }
    }

    func testPlaylistReferencesCascadeAndAlbumDeleteIsAtomic() throws {
        enum Expected: Error { case stop }
        let repository = try makeRepository()
        try repository.insertAlbum(
            album(id: "album", sequence: 1),
            tracks: [track(id: "track", albumID: "album", sequence: 1)]
        )
        let playlist = CatalogPlaylist(id: "playlist", name: "Set", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        try repository.createPlaylist(playlist)
        try repository.replacePlaylistItems(playlistID: playlist.id, trackIDs: ["track", "track"])
        XCTAssertEqual(try repository.playlistItems(playlistID: playlist.id).map(\.trackID), ["track", "track"])
        XCTAssertThrowsError(try repository.replacePlaylistItems(playlistID: playlist.id, trackIDs: ["missing"])) {
            XCTAssertEqual($0 as? CatalogRepositoryError, .missingReference("missing"))
        }
        XCTAssertEqual(try repository.playlistItems(playlistID: playlist.id).map(\.trackID), ["track", "track"])

        XCTAssertThrowsError(try repository.database.transaction {
            try repository.database.execute("DELETE FROM albums WHERE id = ?", [.text("album")])
            throw Expected.stop
        })
        XCTAssertNotNil(try repository.album(id: "album"))
        XCTAssertNotNil(try repository.track(id: "track"))
        XCTAssertEqual(try repository.playlistItems(playlistID: playlist.id).count, 2)

        XCTAssertTrue(try repository.deleteAlbum(id: "album"))
        XCTAssertNil(try repository.track(id: "track"))
        XCTAssertTrue(try repository.playlistItems(playlistID: playlist.id).isEmpty)
    }

    func testSearchNormalizesCaseDiacriticsWhitespaceAndLiteralWildcards() throws {
        let repository = try makeRepository()
        try repository.insertAlbum(
            album(id: "vespertine", sequence: 1, title: "Vespertine 100%", artist: "Björk", genre: "Art Pop"),
            tracks: [track(id: "pagan", albumID: "vespertine", sequence: 1, title: "Pagan Poetry", artist: "Björk")]
        )

        XCTAssertEqual(try repository.search("  BJORK ").albums.map(\.id), ["vespertine"])
        XCTAssertEqual(try repository.search("págan").tracks.map(\.trackID), ["pagan"])
        XCTAssertEqual(try repository.search("100%").albums.map(\.id), ["vespertine"])
        XCTAssertTrue(try repository.search("100_").albums.isEmpty)
    }

    func testPlayCountsCanOnlyMoveForward() throws {
        let repository = try makeRepository()
        try repository.insertAlbum(
            album(id: "album", sequence: 1),
            tracks: [track(id: "track", albumID: "album", sequence: 1)]
        )
        try repository.mergeListening(trackID: "track", playCount: 12, completedCount: 4, lastPlayedAt: Date(timeIntervalSince1970: 20))
        try repository.mergeListening(trackID: "track", playCount: 3, completedCount: 1, lastPlayedAt: Date(timeIntervalSince1970: 10))
        try repository.recordPlay(trackID: "track", completed: true, lastPosition: 8, at: Date(timeIntervalSince1970: 15))

        let state = try XCTUnwrap(repository.listeningState(trackID: "track"))
        XCTAssertEqual(state.playCount, 13)
        XCTAssertEqual(state.completedCount, 5)
        XCTAssertEqual(state.lastPlayedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(try repository.albumPage(sort: .mostPlayed).first?.playCount, 13)
    }

    func testSettingsSkyMigrationAndMainThreadObservationRoundTrip() throws {
        struct Setting: Codable, Equatable { let contrast: Double; let hud: Bool }
        let repository = try makeRepository()
        let expected = Setting(contrast: 0.7, hud: true)
        try repository.setSetting(expected, forKey: "sky")
        XCTAssertEqual(try repository.setting(Setting.self, forKey: "sky"), expected)
        try repository.removeSetting(forKey: "sky")
        XCTAssertNil(try repository.setting(Setting.self, forKey: "sky"))

        let sky = SkyRecord(
            id: "planet-001",
            kind: .planet,
            sequence: 1,
            payload: Data("{\"albums\":20}".utf8),
            updatedAt: Date(timeIntervalSince1970: 4)
        )
        try repository.upsertSkyRecord(sky)
        XCTAssertEqual(try repository.skyRecords(kind: .planet), [sky])

        let stage = MigrationStageRecord(
            sourceStore: "tracks",
            sourceID: "legacy-track",
            status: .pending,
            payload: Data("{}".utf8),
            updatedAt: Date(timeIntervalSince1970: 5)
        )
        try repository.stageMigrationRecord(stage)
        XCTAssertEqual(try repository.migrationRecords(status: .pending), [stage])

        let delivered = expectation(description: "main actor snapshot")
        let observation = repository.observeLibrary { snapshot in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(snapshot.albums.isEmpty)
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 2)
        observation.cancel()

        try repository.deleteSkyRecord(id: sky.id)
        XCTAssertTrue(try repository.skyRecords(kind: .planet).isEmpty)
    }

    func testTenThousandAlbumCatalogueUsesBoundedPages() throws {
        let repository = try makeRepository()
        let records = (1...10_000).map { index in
            (album(id: "album-\(index)", sequence: Int64(index), title: "Record \(index)"), [CatalogTrack]())
        }
        try repository.insertAlbums(records)

        XCTAssertEqual(try repository.database.scalar("SELECT COUNT(*) AS value FROM albums")?.int64, 10_000)
        XCTAssertEqual(try repository.albumPage(offset: 9_950, limit: 50).count, 50)
        XCTAssertThrowsError(try repository.albumPage(limit: 251)) {
            XCTAssertEqual($0 as? CatalogRepositoryError, .invalidPage)
        }
        XCTAssertEqual(try repository.search("Record 9999", limit: 10).albums.map(\.id), ["album-9999"])
    }

    private func makeRepository() throws -> CatalogRepository {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeonRepositoryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        roots.append(root)
        return CatalogRepository(database: try CatalogDatabase(rootURL: root))
    }

    private func album(
        id: String,
        sequence: Int64,
        title: String = "Album",
        artist: String = "Artist",
        genre: String = ""
    ) -> CatalogAlbum {
        CatalogAlbum(
            id: id,
            sequence: sequence,
            title: title,
            artist: artist,
            year: "2026",
            genre: genre,
            artworkKey: nil,
            importedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(sequence))
        )
    }

    private func track(
        id: String,
        albumID: String,
        sequence: Int,
        disc: Int? = 1,
        number: Int? = 1,
        title: String = "Track",
        artist: String = ""
    ) -> CatalogTrack {
        CatalogTrack(
            id: id,
            albumID: albumID,
            sequence: sequence,
            discNumber: disc,
            trackNumber: number,
            title: title,
            artist: artist,
            duration: 180,
            byteCount: 1_024,
            mediaReference: .native(relativePath: "\(id).flac"),
            importedAt: Date(timeIntervalSince1970: TimeInterval(sequence))
        )
    }
}
