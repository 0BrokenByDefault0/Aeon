import XCTest
@testable import App

@MainActor
final class AppContainerTests: XCTestCase {
    func testStartupErrorIdentifiesStageWithoutLeakingPersonalPaths() {
        let native = NSError(domain: NSCocoaErrorDomain, code: 257,
            userInfo: [NSFilePathErrorKey: "/private/music/Personal Album.wav",
                       NSLocalizedDescriptionKey: "Secret file path"])
        do {
            let _: Void = try AppStartupFailure.perform("catalogue") { throw native }
            XCTFail("Expected the original failure to remain a failure")
        } catch {
            guard let failure = error as? AppStartupFailure else { return XCTFail("Missing startup stage") }
            XCTAssertEqual(failure.stage, "catalogue")
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
            XCTAssertEqual(failure.nativeCode, 257)
            XCTAssertFalse(failure.message.contains("Personal Album"))
            XCTAssertFalse(failure.message.contains("Secret"))
            XCTAssertFalse(failure.message.contains("Check available device storage"))
        }
    }

    func testContainerCreatesOneStableNativeServiceGraph() throws {
        let container = AppContainer.inMemory()
        let services = try XCTUnwrap(container.services)

        XCTAssertTrue(services.catalogDatabase === container.services?.catalogDatabase)
        XCTAssertTrue(services.catalogRepository === container.services?.catalogRepository)
        XCTAssertTrue(services.artworkStore === container.services?.artworkStore)
        XCTAssertTrue(services.mediaStore === container.services?.mediaStore)
        XCTAssertTrue(services.playbackStateStore === container.services?.playbackStateStore)
        XCTAssertTrue(services.diagnosticsLog === container.services?.diagnosticsLog)
        XCTAssertTrue(services.metadataProbe === container.services?.metadataProbe)
        XCTAssertTrue(services.archiveWriter === container.services?.archiveWriter)
        XCTAssertTrue(services.archiveRestorer === container.services?.archiveRestorer)
        XCTAssertTrue(services.skyRepository === container.services?.skyRepository)
        XCTAssertTrue(services.audioEngineGraph === container.services?.audioEngineGraph)
        XCTAssertTrue(services.spectrumAnalyzer === container.services?.spectrumAnalyzer)
        XCTAssertTrue(services.queueScheduler === container.services?.queueScheduler)
        XCTAssertTrue(services.playbackCoordinator === container.services?.playbackCoordinator)
        XCTAssertTrue(services.audioSessionController === container.services?.audioSessionController)
        XCTAssertTrue(services.recoveryCoordinator === container.services?.recoveryCoordinator)
        XCTAssertTrue(services.playbackController === container.services?.playbackController)
        XCTAssertTrue(services.remoteCommandCoordinator === container.services?.remoteCommandCoordinator)
        XCTAssertTrue(services.skySceneController === container.services?.skySceneController)
        XCTAssertEqual(container.launchState, .ready)
    }

    func testInMemoryContainerUsesOnlyItsTemporaryRoot() throws {
        let container = AppContainer.inMemory()
        let roots = try XCTUnwrap(container.roots)
        let commonRoot = roots.applicationSupportURL.deletingLastPathComponent().standardizedFileURL.path

        XCTAssertTrue(commonRoot.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        XCTAssertTrue(roots.documentsURL.standardizedFileURL.path.hasPrefix(commonRoot))
        XCTAssertTrue(roots.temporaryURL.standardizedFileURL.path.hasPrefix(commonRoot))
        XCTAssertTrue(try XCTUnwrap(container.services).catalogDatabase.url.path.hasPrefix(commonRoot))
        XCTAssertTrue(try XCTUnwrap(container.services).artworkStore.rootURL.path.hasPrefix(commonRoot))
        XCTAssertTrue(try XCTUnwrap(container.services).mediaStore.mediaRoot.path.hasPrefix(commonRoot))
    }

    func testStartupFailureCanRetryWithoutDuplicatingServices() throws {
        enum Failure: Error { case unavailable }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var rootAttempts = 0
        var serviceCreations = 0
        let container = AppContainer(
            rootsProvider: {
                rootAttempts += 1
                if rootAttempts == 1 { throw Failure.unavailable }
                return try AppStorageRoots.temporary(at: root, fileManager: .default)
            },
            servicesFactory: { roots in
                serviceCreations += 1
                return try AppServices.production(roots: roots)
            },
            inspectLegacyLibrary: false
        )

        guard case .recovery(let issue) = container.launchState else {
            return XCTFail("Startup failure did not reach recovery")
        }
        XCTAssertEqual(issue.code, "startup_failed")
        XCTAssertNil(container.services)

        container.retryStartup()
        XCTAssertEqual(container.launchState, .ready)
        XCTAssertEqual(rootAttempts, 2)
        XCTAssertEqual(serviceCreations, 1)

        container.retryStartup()
        XCTAssertEqual(serviceCreations, 1)
    }

    func testRootViewRequiresAnInjectedContainer() {
        let container = AppContainer.inMemory()
        _ = AeonRootView(container: container)
    }

    func testQuarantinedCatalogueProducesRestoreAndFreshStartState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = try AppStorageRoots.temporary(at: root, fileManager: .default)
        let recovery = CatalogRecovery(
            originalDatabaseURL: root.appendingPathComponent("catalog.sqlite3"),
            quarantineDirectory: root.appendingPathComponent("Recovery/catalog-1"),
            preservedFiles: ["catalog.sqlite3"]
        )
        let container = AppContainer(
            rootsProvider: { roots },
            servicesFactory: { _ in throw CatalogDatabaseError.recoveryRequired(recovery) },
            inspectLegacyLibrary: false
        )

        guard case .recovery(let issue) = container.launchState else {
            return XCTFail("Corrupt catalogue did not reach recovery")
        }
        XCTAssertEqual(issue.code, "catalog_quarantined")
        XCTAssertEqual(issue.catalogRecovery, recovery)
        XCTAssertEqual(container.roots, roots)
        XCTAssertNil(container.services)
    }

    func testFailedFreshStartRollsBackAndFailedRollbackKeepsRecoveryJournal() throws {
        for failRollback in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let roots = try AppStorageRoots.temporary(at: root, fileManager: .default)
            let manager = EraseFailureFileManager()
            var attempts = 0
            let container = AppContainer(rootsProvider: { roots }, servicesFactory: { roots in
                attempts += 1
                let services = try AppServices.production(roots: roots, startSpectrum: false, startPlayback: false)
                if attempts == 2 {
                    services.playbackController.stopRefreshing()
                    services.playbackCoordinator.shutdown()
                    services.catalogDatabase.close()
                    manager.failRollback = failRollback
                    throw NSError(domain: "EraseFixture", code: 1)
                }
                return services
            }, inspectLegacyLibrary: false, cleanupFileManager: manager)
            let services = try XCTUnwrap(container.services)
            try services.catalogRepository.insertAlbum(CatalogAlbum(id: "survivor", sequence: 1, title: "Survivor", artist: "Artist", year: "2026", genre: "Jazz", artworkKey: nil, importedAt: Date(), updatedAt: Date()), tracks: [])
            let music = roots.documentsURL.appendingPathComponent("Music/_Imported/music.wav")
            try FileManager.default.createDirectory(at: music.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original music".utf8).write(to: music)
            XCTAssertFalse(container.eraseEverything())
            if failRollback {
                let journal = roots.applicationSupportURL.appendingPathComponent("Aeon/EraseQuarantine/pending.json")
                XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
                XCTAssertNil(container.services)
                manager.failRollback = false
                container.retryStartup()
            }
            XCTAssertEqual(container.launchState, .ready)
            XCTAssertNotNil(try container.services?.catalogRepository.album(id: "survivor"))
            XCTAssertEqual(try Data(contentsOf: music), Data("original music".utf8))
        }
    }

    func testEraseQuarantinesOwnedDataPreservesAdoptedAndLegacyStorageThenPurgesAfterRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = try AppStorageRoots.temporary(at: root, fileManager: .default)
        let adopted = roots.documentsURL.appendingPathComponent("Music/Owned/adopted.wav", isDirectory: false)
        let copied = roots.documentsURL.appendingPathComponent("Music/_Imported/album/copied.wav", isDirectory: false)
        let indexedDB = roots.applicationSupportURL.appendingPathComponent("WebKit/WebsiteData/IndexedDB/legacy.data", isDirectory: false)
        for url in [adopted, copied, indexedDB] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(url.lastPathComponent.utf8).write(to: url)
        }

        var first: AppContainer? = AppContainer(
            rootsProvider: { roots },
            servicesFactory: { try AppServices.production(roots: $0) },
            inspectLegacyLibrary: false
        )
        let oldServices = try XCTUnwrap(first?.services)
        let album = CatalogAlbum(
            id: "owned", sequence: 1, title: "Owned", artist: "Aeon", year: "2026", genre: "",
            artworkKey: nil, importedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
        )
        try oldServices.catalogRepository.insertAlbum(album, tracks: [])

        XCTAssertTrue(try XCTUnwrap(first).eraseEverything())
        XCTAssertTrue(try XCTUnwrap(first?.services).catalogRepository.albumPage().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: adopted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexedDB.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        let quarantine = roots.applicationSupportURL.appendingPathComponent("Aeon/EraseQuarantine", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("pending.json").path))

        first?.services?.catalogDatabase.close()
        first = nil
        let relaunched = AppContainer(
            rootsProvider: { roots },
            servicesFactory: { try AppServices.production(roots: $0) },
            inspectLegacyLibrary: false
        )
        XCTAssertEqual(relaunched.launchState, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: adopted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexedDB.path))
    }
}

private final class EraseFailureFileManager: FileManager, @unchecked Sendable {
    var failRollback = false
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failRollback && srcURL.path.contains("EraseQuarantine") { throw NSError(domain: "EraseFixture", code: 2) }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
