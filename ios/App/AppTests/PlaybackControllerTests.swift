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

    func testAutoplayWaitsForTheLoadToLandBeforeItStarts() {
        // A load is asynchronous. Calling play() straight after it reached the
        // transport queue first, found nothing loaded, and failed — which put a
        // track in the player bar and left it sitting there.
        let coordinator = ControllerCoordinator()
        coordinator.state = snapshot(version: 1, trackID: "track")
        coordinator.holdsLoad = true
        let controller = PlaybackController(coordinator: coordinator)

        controller.load(track: track(id: "track"), queue: [], index: 0, autoplay: true)
        XCTAssertEqual(coordinator.playCount, 0, "Playback started before the track was loaded")

        coordinator.releaseLoad()
        XCTAssertEqual(coordinator.playCount, 1)
    }

    func testAFailedLoadNeverStartsPlayback() {
        let coordinator = ControllerCoordinator()
        coordinator.state = nil
        let controller = PlaybackController(coordinator: coordinator)

        controller.load(track: track(id: "missing"), autoplay: true)

        XCTAssertEqual(coordinator.playCount, 0)
    }

    func testLoadWithoutAutoplayLeavesTheTrackWaiting() {
        let coordinator = ControllerCoordinator()
        coordinator.state = snapshot(version: 1, trackID: "track")
        let controller = PlaybackController(coordinator: coordinator)

        controller.load(track: track(id: "track"))

        XCTAssertEqual(coordinator.playCount, 0)
    }

    func testPlayNextLandsBehindTheCurrentTrackAndTheRestGoesToTheEnd() {
        let items = (0 ..< 3).map { QueueItem(trackID: "t\($0)", albumID: "a", mediaRef: .documents(relativePath: "t\($0).wav")) }
        let coordinator = ControllerCoordinator()
        coordinator.state = snapshot(version: 1, trackID: "t0", queue: items, index: 1)
        let controller = PlaybackController(coordinator: coordinator)
        controller.accept(snapshot: snapshot(version: 2, trackID: "t1", queue: items, index: 1))

        let added = QueueItem(trackID: "new", albumID: "a", mediaRef: .documents(relativePath: "new.wav"))
        XCTAssertTrue(controller.insertNext([added]))
        XCTAssertEqual(coordinator.queuedOrders.last?.map(\.trackID), ["t0", "t1", "new", "t2"])

        XCTAssertTrue(controller.appendToQueue([added]))
        XCTAssertEqual(coordinator.queuedOrders.last?.last?.trackID, "new")
    }

    func testQueueingWithNothingLoadedReportsThatItCouldNotBeDone() {
        let controller = PlaybackController(coordinator: ControllerCoordinator())
        let added = QueueItem(trackID: "new", albumID: "a", mediaRef: .documents(relativePath: "new.wav"))

        XCTAssertFalse(controller.insertNext([added]), "There is no next without a current track")
        XCTAssertFalse(controller.appendToQueue([added]))
    }

    private func track(id: String) -> CatalogTrack {
        CatalogTrack(
            id: id, albumID: "album", sequence: 1, discNumber: 1, trackNumber: 1,
            title: id, artist: "", duration: 60, byteCount: 32,
            mediaReference: .documents(relativePath: "\(id).wav"),
            importedAt: Date(timeIntervalSince1970: 1)
        )
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

    private func snapshot(
        version: UInt64,
        trackID: String?,
        intent: PlaybackIntent = .paused,
        queue: [QueueItem] = [],
        index: Int? = nil
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            version: version,
            trackID: trackID,
            queueRevision: 0,
            queue: queue,
            queueIndex: index,
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
    private(set) var queuedOrders: [[QueueItem]] = []
    /// Holds the load's completion the way a real one does while the file is
    /// inspected, so a test can see what happens in between.
    var holdsLoad = false
    private var heldLoad: (() -> Void)?

    func releaseLoad() {
        let held = heldLoad
        heldLoad = nil
        held?()
    }

    func initialize(completion: @escaping PlaybackCommandCompletion) {
        initializeCount += 1
        completion(state.map(Result.success) ?? .failure(failure))
    }

    func load(trackID: String, mediaRef: MediaReference, queue: [QueueItem]?, index: Int?, completion: @escaping PlaybackCommandCompletion) {
        let result = state.map(Result.success) ?? .failure(failure)
        guard holdsLoad else { completion(result); return }
        heldLoad = { completion(result) }
    }
    func play(completion: @escaping PlaybackCommandCompletion) { playCount += 1; complete(completion) }
    func pause(completion: @escaping PlaybackCommandCompletion) { complete(completion) }
    func toggle(completion: @escaping PlaybackCommandCompletion) { complete(completion) }
    func seek(seconds: Double, completion: @escaping PlaybackCommandCompletion) { seekPositions.append(seconds); complete(completion) }
    func next(completion: @escaping PlaybackCommandCompletion) { nextCount += 1; complete(completion) }
    func previous(completion: @escaping PlaybackCommandCompletion) { complete(completion) }
    func setQueue(items: [QueueItem], index: Int, revision: UInt64, completion: @escaping PlaybackCommandCompletion) {
        queuedOrders.append(items)
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
