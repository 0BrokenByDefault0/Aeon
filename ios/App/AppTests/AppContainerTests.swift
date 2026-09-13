import XCTest
@testable import App

@MainActor
final class AppContainerTests: XCTestCase {
    func testContainerCreatesOneStableNativeServiceGraph() throws {
        let container = AppContainer.inMemory()
        let services = try XCTUnwrap(container.services)

        XCTAssertTrue(services.mediaStore === container.services?.mediaStore)
        XCTAssertTrue(services.playbackStateStore === container.services?.playbackStateStore)
        XCTAssertTrue(services.diagnosticsLog === container.services?.diagnosticsLog)
        XCTAssertTrue(services.metadataProbe === container.services?.metadataProbe)
        XCTAssertTrue(services.audioEngineGraph === container.services?.audioEngineGraph)
        XCTAssertTrue(services.queueScheduler === container.services?.queueScheduler)
        XCTAssertTrue(services.playbackCoordinator === container.services?.playbackCoordinator)
        XCTAssertEqual(container.launchState, .ready)
    }

    func testInMemoryContainerUsesOnlyItsTemporaryRoot() throws {
        let container = AppContainer.inMemory()
        let roots = try XCTUnwrap(container.roots)
        let commonRoot = roots.applicationSupportURL.deletingLastPathComponent().standardizedFileURL.path

        XCTAssertTrue(commonRoot.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        XCTAssertTrue(roots.documentsURL.standardizedFileURL.path.hasPrefix(commonRoot))
        XCTAssertTrue(roots.temporaryURL.standardizedFileURL.path.hasPrefix(commonRoot))
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
}
