import XCTest
@testable import App

final class MediaStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testStoreOwnsAeonMediaAndSiblingIncomingDirectories() throws {
        let store = try MediaStore(baseURL: tempURL)
        XCTAssertEqual(store.mediaRoot, tempURL.appendingPathComponent("Aeon/Media", isDirectory: true))
        XCTAssertEqual(store.incomingRoot, tempURL.appendingPathComponent("Aeon/.incoming", isDirectory: true))
    }

    func testImportDoesNotReplaceExistingMediaUntilVerified() throws {
        let store = try MediaStore(baseURL: tempURL)
        let source = tempURL.appendingPathComponent("incoming.wav")
        try Data([0, 1, 2, 3]).write(to: source)

        XCTAssertThrowsError(try store.importFile(sourceURL: source, stableID: "track-1", verifier: { _ in false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(stableID: "track-1", fileExtension: "wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.incomingRoot.appendingPathComponent("track-1.partial").path))
    }

    func testFailedReplacementPreservesExistingVerifiedMedia() throws {
        let store = try MediaStore(baseURL: tempURL)
        let original = tempURL.appendingPathComponent("original.wav")
        let replacement = tempURL.appendingPathComponent("replacement.wav")
        try Data([1, 2, 3]).write(to: original)
        let destination = try store.importFile(sourceURL: original, stableID: "track", verifier: { _ in true })
        try Data([9, 9, 9]).write(to: replacement)

        XCTAssertThrowsError(try store.importFile(sourceURL: replacement, stableID: "track", verifier: { _ in false }))
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testRejectsUnsafeStableIDsAndNativePaths() throws {
        let store = try MediaStore(baseURL: tempURL)
        let source = tempURL.appendingPathComponent("source.wav")
        try Data([1]).write(to: source)
        for identifier in ["", ".", "..", "../escape", "a/b", "a\\b", " track"] {
            XCTAssertThrowsError(try store.importFile(sourceURL: source, stableID: identifier, verifier: { _ in true }))
        }
        for path in ["../escape.wav", "/tmp/escape.wav", "sub/../../escape.wav", "sub//file.wav"] {
            XCTAssertThrowsError(try store.resolve(.native(relativePath: path)))
        }
    }

    func testResolvesNativeInsideMediaRootAndLegacyRequiresMigration() throws {
        let store = try MediaStore(baseURL: tempURL)
        XCTAssertEqual(try store.resolve(.native(relativePath: "album/track.wav")), store.mediaRoot.appendingPathComponent("album/track.wav"))
        XCTAssertThrowsError(try store.resolve(.legacyBlob(trackID: "old"))) { error in
            XCTAssertEqual(error as? MediaStoreError, .migrationRequired(trackID: "old"))
        }
    }

    func testBookmarkResolutionOwnsSecurityScopeUntilBalancedRelease() throws {
        let external = tempURL.appendingPathComponent("external.wav")
        var starts = 0
        var stops = 0
        let store = try MediaStore(
            baseURL: tempURL,
            bookmarkResolver: { _ in (external, false) },
            beginScopedAccess: { _ in starts += 1; return true },
            endScopedAccess: { _ in stops += 1 }
        )
        XCTAssertEqual(try store.resolve(.externalBookmark(Data([1]))), external)
        XCTAssertEqual(try store.resolve(.externalBookmark(Data([1]))), external)
        XCTAssertEqual(starts, 1)
        store.release(external)
        XCTAssertEqual(stops, 0)
        store.release(external)
        XCTAssertEqual(stops, 1)
    }

    func testRejectsStaleAndDeniedBookmarks() throws {
        let external = tempURL.appendingPathComponent("external.wav")
        let stale = try MediaStore(baseURL: tempURL, bookmarkResolver: { _ in (external, true) })
        XCTAssertThrowsError(try stale.resolve(.externalBookmark(Data([1])))) { error in
            XCTAssertEqual(error as? MediaStoreError, .staleBookmark)
        }
        let denied = try MediaStore(baseURL: tempURL, bookmarkResolver: { _ in (external, false) }, beginScopedAccess: { _ in false })
        XCTAssertThrowsError(try denied.resolve(.externalBookmark(Data([1])))) { error in
            XCTAssertEqual(error as? MediaStoreError, .securityScopedAccessDenied)
        }
    }
}
