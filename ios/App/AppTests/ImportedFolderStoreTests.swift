import XCTest
@testable import App

final class ImportedFolderStoreTests: XCTestCase {
    private var root: URL!
    private var database: CatalogDatabase!
    private var repository: CatalogRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeonImportedFolderStoreTests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try CatalogDatabase(rootURL: root.appendingPathComponent("Aeon", isDirectory: true))
        repository = CatalogRepository(database: database)
    }

    override func tearDown() {
        database?.close(); database = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testARememberedFolderSurvivesIntoTheNextLaunchAndReopensWithScopedAccess() throws {
        let folder = URL(fileURLWithPath: "/private/var/mobile/Music", isDirectory: true)
        var began: [URL] = []
        let store = makeStore(begin: { began.append($0); return true })

        try store.remember(folder)

        // A fresh store stands in for a relaunch: nothing is held in memory.
        let reopened = makeStore(begin: { began.append($0); return true })
        XCTAssertEqual(reopened.folders().map(\.path), [folder.path])
        XCTAssertEqual(reopened.folders().map(\.name), ["Music"])
        let resolved = try reopened.resolve(path: folder.path)
        XCTAssertEqual(resolved.path, folder.path)
        XCTAssertEqual(began, [folder])
    }

    func testAFolderWhoseGrantIsRefusedReportsAccessDeniedRatherThanReturningAURL() throws {
        let folder = URL(fileURLWithPath: "/private/var/mobile/Revoked", isDirectory: true)
        try makeStore().remember(folder)
        let store = makeStore(begin: { _ in false })

        XCTAssertThrowsError(try store.resolve(path: folder.path)) {
            XCTAssertEqual($0 as? ImportedFolderError, .accessDenied)
        }
    }

    func testAFolderThatWasNeverRememberedIsReportedUnavailable() {
        XCTAssertThrowsError(try makeStore().resolve(path: "/private/var/mobile/Unknown")) {
            XCTAssertEqual($0 as? ImportedFolderError, .unavailable)
        }
    }

    func testAStaleBookmarkIsRefreshedInPlaceSoTheNextLaunchUsesTheNewOne() throws {
        let folder = URL(fileURLWithPath: "/private/var/mobile/Moved", isDirectory: true)
        try makeStore(bookmark: { _ in Data("first".utf8) }).remember(folder)

        let store = makeStore(
            bookmark: { _ in Data("second".utf8) },
            resolve: { _ in (folder, true) }
        )
        _ = try store.resolve(path: folder.path)

        XCTAssertEqual(store.folders().first?.bookmark, Data("second".utf8))
    }

    func testRememberingAFolderAgainKeepsOneEntryAndForgettingRemovesIt() throws {
        let folder = URL(fileURLWithPath: "/private/var/mobile/Repeat", isDirectory: true)
        let store = makeStore()

        try store.remember(folder)
        try store.remember(folder)
        XCTAssertEqual(store.folders().count, 1)

        store.forget(path: folder.path)
        XCTAssertTrue(store.folders().isEmpty)
    }

    func testBookmarkCreationFailureIsReportedRatherThanSwallowed() {
        struct Denied: Error {}
        let store = makeStore(bookmark: { _ in throw Denied() })

        XCTAssertThrowsError(try store.remember(URL(fileURLWithPath: "/private/var/mobile/Denied"))) {
            XCTAssertEqual($0 as? ImportedFolderError, .accessDenied)
        }
    }

    private func makeStore(
        bookmark: ((URL) throws -> Data)? = nil,
        resolve: ((Data) throws -> (URL, Bool))? = nil,
        begin: @escaping (URL) -> Bool = { _ in true }
    ) -> ImportedFolderStore {
        ImportedFolderStore(
            repository: repository,
            makeBookmark: bookmark ?? { Data($0.path.utf8) },
            resolveBookmark: resolve ?? { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self), isDirectory: true), false) },
            beginScopedAccess: begin,
            endScopedAccess: { _ in },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}
