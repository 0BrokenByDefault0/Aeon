import ImageIO
import UIKit
import XCTest
@testable import App

final class CatalogDatabaseTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    func testFreshDatabaseEnablesSchemaForeignKeysIndicesAndWAL() throws {
        let database = try makeDatabase()

        XCTAssertEqual(try database.schemaVersion, CatalogSchema.currentVersion)
        XCTAssertTrue(try database.foreignKeysEnabled)
        XCTAssertEqual(try database.journalMode.lowercased(), "wal")
        XCTAssertEqual(
            Set(try database.tableNames()),
            Set(["albums", "tracks", "playlists", "playlist_items", "listening", "settings", "sky_records", "migration_staging"])
        )
        XCTAssertTrue(Set(try database.indexNames()).isSuperset(of: [
            "albums_sequence_idx", "albums_artist_idx", "tracks_album_order_idx",
            "playlist_items_track_idx", "listening_recent_idx", "sky_records_kind_idx",
            "migration_staging_status_idx"
        ]))

        XCTAssertThrowsError(try database.execute(
            """
            INSERT INTO tracks(
                id, album_id, sequence, title, artist, normalized_title, normalized_artist,
                byte_count, media_kind, imported_at
            ) VALUES(?, ?, 1, 'Missing', '', 'missing', '', 0, 'native', 0)
            """,
            [.text("orphan"), .text("missing-album")]
        ))
    }

    func testTransactionRollsBackEveryStatement() throws {
        enum Expected: Error { case stop }
        let database = try makeDatabase()

        XCTAssertThrowsError(try database.transaction {
            try database.execute(
                "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)",
                [.text("one"), .blob(Data([1])), .real(1)]
            )
            try database.execute(
                "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)",
                [.text("two"), .blob(Data([2])), .real(2)]
            )
            throw Expected.stop
        })
        XCTAssertEqual(try database.scalar("SELECT COUNT(*) AS value FROM settings")?.int64, 0)
    }

    func testVersionTwoFixtureMigratesTracksAndReferencesWithoutLosingRows() throws {
        let root = makeRoot()
        let url = root.appendingPathComponent("Catalog/catalog.sqlite3")
        let recovery = root.appendingPathComponent("Recovery")
        var fixture: CatalogDatabase? = try CatalogDatabase(
            url: url,
            recoveryDirectory: recovery,
            targetSchemaVersion: 2
        )
        try fixture?.execute(
            """
            INSERT INTO albums(
                id, sequence, title, artist, year, genre, normalized_title,
                normalized_artist, imported_at, updated_at
            ) VALUES('fixture', 1, 'First', 'Aeon', '', '', 'first', 'aeon', 1, 1)
            """
        )
        try fixture?.execute(
            """
            INSERT INTO tracks(
                id, album_id, sequence, title, artist, normalized_title, normalized_artist,
                byte_count, media_kind, media_path, imported_at
            ) VALUES('track', 'fixture', 1, 'Signal', 'Aeon', 'signal', 'aeon', 42, 'native', 'track.wav', 1)
            """
        )
        try fixture?.execute("INSERT INTO playlists(id, name, created_at, updated_at) VALUES('list', 'Route', 1, 1)")
        try fixture?.execute("INSERT INTO playlist_items(playlist_id, position, track_id) VALUES('list', 0, 'track')")
        try fixture?.execute("INSERT INTO listening(track_id, play_count, completed_count, last_position) VALUES('track', 7, 2, 3)")
        try fixture?.execute(
            "INSERT INTO sky_records(id, kind, sequence, payload, updated_at) VALUES('planet:1', 'planet', 1, ?, 1)",
            [.blob(Data("{\"legacy\":true}".utf8))]
        )
        fixture?.close()
        fixture = nil

        let migrated = try CatalogDatabase(url: url, recoveryDirectory: recovery)
        XCTAssertEqual(try migrated.schemaVersion, CatalogSchema.currentVersion)
        XCTAssertEqual(try migrated.scalar("SELECT COUNT(*) AS value FROM albums")?.int64, 1)
        XCTAssertEqual(
            try migrated.scalar("SELECT normalized_genre AS value FROM albums WHERE id = 'fixture'")?.string,
            ""
        )
        XCTAssertTrue(try migrated.tableNames().contains("migration_staging"))
        XCTAssertEqual(try migrated.scalar("SELECT COUNT(*) AS value FROM tracks")?.int64, 1)
        XCTAssertEqual(try migrated.scalar("SELECT COUNT(*) AS value FROM playlist_items")?.int64, 1)
        XCTAssertEqual(try migrated.scalar("SELECT play_count AS value FROM listening WHERE track_id = 'track'")?.int64, 7)
        XCTAssertEqual(
            try migrated.query("SELECT payload FROM sky_records WHERE id = 'planet:1'").first?.data("payload"),
            Data("{\"legacy\":true}".utf8)
        )
        try migrated.execute(
            "INSERT INTO sky_records(id, kind, sequence, payload, updated_at) VALUES('star:fixture', 'star', 1, ?, 1)",
            [.blob(Data("{}".utf8))]
        )
        XCTAssertTrue(try migrated.foreignKeysEnabled)
        XCTAssertTrue((try migrated.query("PRAGMA foreign_key_check")).isEmpty)
        try migrated.execute("UPDATE tracks SET media_kind = 'documents', media_path = 'Music/track.wav' WHERE id = 'track'")
    }

    func testCorruptDatabaseAndSidecarsAreQuarantinedWithoutTouchingUserData() throws {
        let root = makeRoot()
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let databaseURL = catalog.appendingPathComponent(CatalogDatabase.filename)
        let media = root.appendingPathComponent("Media/song.flac")
        let indexedDB = root.appendingPathComponent("Legacy/IndexedDB", isDirectory: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: indexedDB, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: databaseURL)
        try Data([1]).write(to: URL(fileURLWithPath: databaseURL.path + "-wal"))
        try Data([2]).write(to: URL(fileURLWithPath: databaseURL.path + "-shm"))
        try Data([3]).write(to: media)

        var recovery: CatalogRecovery?
        XCTAssertThrowsError(try CatalogDatabase(rootURL: root)) { error in
            guard case CatalogDatabaseError.recoveryRequired(let value) = error else {
                return XCTFail("Expected recoveryRequired, got \(error)")
            }
            recovery = value
        }

        let resolved = try XCTUnwrap(recovery)
        XCTAssertEqual(Set(resolved.preservedFiles), Set(["catalog.sqlite3", "catalog.sqlite3-wal", "catalog.sqlite3-shm"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.quarantineDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexedDB.path))

        let clean = try CatalogDatabase(rootURL: root)
        XCTAssertEqual(try clean.schemaVersion, CatalogSchema.currentVersion)
    }

    func testArtworkStoreDownsamplesJPEGAndRejectsOtherFormatsAndUnsafeKeys() throws {
        let root = makeRoot()
        let store = try ArtworkStore(rootURL: root.appendingPathComponent("Artwork"), maximumPixelSize: 128)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 320))
        let image = renderer.image { context in
            UIColor(red: 0.15, green: 0.2, blue: 0.25, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 1))

        let key = try store.store(jpeg, key: "album-01")
        XCTAssertEqual(key, "album-01.jpg")
        let url = try store.url(forKey: key)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth] as? Int ?? .max, 128)
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelHeight] as? Int ?? .max, 128)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path).contains { $0.hasSuffix(".partial") })

        XCTAssertThrowsError(try store.store(try XCTUnwrap(image.pngData()), key: "png")) {
            XCTAssertEqual($0 as? ArtworkStoreError, .unsupportedImage)
        }
        XCTAssertThrowsError(try store.url(forKey: "../album-01.jpg")) {
            XCTAssertEqual($0 as? ArtworkStoreError, .unsafeStoredKey)
        }
    }

    private func makeDatabase() throws -> CatalogDatabase {
        try CatalogDatabase(rootURL: makeRoot())
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeonCatalogTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        roots.append(root)
        return root
    }
}
