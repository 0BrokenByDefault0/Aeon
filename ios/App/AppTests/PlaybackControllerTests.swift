import MediaPlayer
import XCTest
@testable import App

@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testStateFollowsNewestSnapshotAndCannotRollBackward() {
        let coordinator = ControllerCoordinator()
        let controller = PlaybackController(coordinator: coordinator)

        controller.accept(snapshot: snapshot(version: 4, trackID: "new"))
        controller.accept(snapshot: snapshot(version: 3, trackID: "stale"))

        XCTAssertEqual(controller.snapshot?.version, 4)
        XCTAssertEqual(controller.snapshot?.trackID, "new")
    }

    func testFailureRemainsInlineUntilDismissed() {
        let controller = PlaybackController(coordinator: ControllerCoordinator())
        controller.accept(snapshot: snapshot(version: 2, trackID: "track"))

        controller.accept(
            failure: PlaybackFailure(code: "decoder_error", message: "Could not decode", recoverable: true, trackID: "track"),
            version: 2
        )

        XCTAssertEqual(controller.failure?.code, "decoder_error")
        controller.dismissFailure()
        XCTAssertNil(controller.failure)
    }

    func testSupersededCommandFailureIsNotShown() {
        let controller = PlaybackController(coordinator: ControllerCoordinator())
        controller.accept(snapshot: snapshot(version: 3, trackID: "current"))

        controller.accept(
            failure: PlaybackFailure(code: "stale_operation", message: "Superseded", recoverable: true, trackID: "old"),
            version: 3
        )

        XCTAssertNil(controller.failure)
    }

    func testForegroundRequestsAuthoritativeSnapshot() {
        let coordinator = ControllerCoordinator()
        coordinator.state = snapshot(version: 8, trackID: "foreground")
        let controller = PlaybackController(coordinator: coordinator)

        controller.applicationDidEnterForeground()

        XCTAssertEqual(coordinator.stateRequestCount, 1)
        XCTAssertEqual(controller.snapshot?.version, 8)
    }

    func testStartInitializesThroughCoordinator() {
        let coordinator = ControllerCoordinator()
        coordinator.state = snapshot(version: 1, trackID: nil)
        let controller = PlaybackController(coordinator: coordinator)

        controller.start()

        XCTAssertEqual(coordinator.initializeCount, 1)
        XCTAssertTrue(controller.isInitialized)
    }

    func testBackgroundStopsRefreshingAndForegroundStillRequestsAuthority() {
        let coordinator = ControllerCoordinator()
        coordinator.state = snapshot(version: 1, trackID: "track", intent: .playing)
        let controller = PlaybackController(coordinator: coordinator)
        controller.accept(snapshot: coordinator.state!)

        controller.applicationDidEnterBackground()
        controller.applicationDidEnterForeground()

        XCTAssertEqual(coordinator.stateRequestCount, 1)
    }

    func testLockScreenCommandsRouteToThePlaybackController() throws {
        let coordinator = ControllerCoordinator()
        coordinator.state = snapshot(version: 1, trackID: "track")
        let controller = PlaybackController(coordinator: coordinator)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = RemoteCommandCoordinator(
            controller: controller,
            catalog: CatalogRepository(database: try CatalogDatabase(rootURL: root)),
            artworkStore: try ArtworkStore(rootURL: root.appendingPathComponent("Artwork"))
        )

        XCTAssertEqual(remote.handle(.play), .success)
        XCTAssertEqual(remote.handle(.next), .success)
        XCTAssertEqual(remote.handle(.seek(19.25)), .success)

        XCTAssertEqual(coordinator.playCount, 1)
        XCTAssertEqual(coordinator.nextCount, 1)
        XCTAssertEqual(coordinator.seekPositions, [19.25])
    }

    private func snapshot(version: UInt64, trackID: String?, intent: PlaybackIntent = .paused) -> PlaybackSnapshot {
        PlaybackSnapshot(
            version: version,
            trackID: trackID,
            queueRevision: 0,
            queue: [],
            queueIndex: nil,
            position: 0,
            intent: intent,
            replayGainMode: .off,
            replayGainPreampDB: 0,
            masterVolume: 1,
            eqEnabled: false,
            eqBands: [],
            route: nil,
            sourceFormat: nil,
            outputFormat: nil,
            timestamp: Date(timeIntervalSince1970: 1)
        )
    }
}

private final class ControllerCoordinator: PlaybackCoordinating {
    weak var delegate: PlaybackCoordinatorDelegate?
    var state: PlaybackSnapshot?
    private(set) var initializeCount = 0
    private(set) var stateRequestCount = 0
    private(set) var playCount = 0
    private(set) var nextCount = 0
    private(set) var seekPositions: [TimeInterval] = []

    func initialize(completion: @escaping PlaybackCommandCompletion) {
        initializeCount += 1
        completion(state.map(Result.success) ?? .failure(failure))
    }

    func load(trackID: String, mediaRef: MediaReference, queue: [QueueItem]?, index: Int?, completion: @escaping PlaybackCommandCompletion) {
        completion(state.map(Result.success) ?? .failure(failure))
    }
    func play(completion: @escaping PlaybackCommandCompletion) { playCount += 1; complete(completion) }
    func pause(completion: @escaping PlaybackCommandCompletion) { complete(completion) }
    func toggle(completion: @escaping PlaybackCommandCompletion) { complete(completion) }
    func seek(seconds: Double, completion: @escaping PlaybackCommandCompletion) { seekPositions.append(seconds); complete(completion) }
    func next(completion: @escaping PlaybackCommandCompletion) { nextCount += 1; complete(completion) }
    func previous(completion: @escaping PlaybackCommandCompletion) { complete(completion) }
    func setQueue(items: [QueueItem], index: Int, revision: UInt64, completion: @escaping PlaybackCommandCompletion) {
        complete(completion)
    }
    func setVolume(_ value: Float, completion: @escaping PlaybackCommandCompletion) { complete(completion) }
    func setReplayGainMode(_ mode: ReplayGainMode, completion: @escaping PlaybackCommandCompletion) { complete(completion) }
    func setReplayGainPreamp(_ db: Double, completion: @escaping PlaybackCommandCompletion) { complete(completion) }
    func setEQ(enabled: Bool, bands: [EQBand], completion: @escaping PlaybackCommandCompletion) { complete(completion) }
    func setRepeatMode(_ mode: RepeatMode, completion: @escaping PlaybackCommandCompletion) { complete(completion) }

    func getState(completion: @escaping (PlaybackSnapshot) -> Void) {
        stateRequestCount += 1
        if let state { completion(state) }
    }

    private var failure: PlaybackFailure {
        PlaybackFailure(code: "no_state", message: "No state", recoverable: true, trackID: nil)
    }

    private func complete(_ completion: @escaping PlaybackCommandCompletion) {
        completion(state.map(Result.success) ?? .failure(failure))
    }
}
