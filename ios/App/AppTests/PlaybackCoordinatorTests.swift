import Capacitor
import XCTest
@testable import App

final class PlaybackCoordinatorTests: XCTestCase {
    func testNativeAudioPluginExportsStableBridgeContract() {
        let plugin = NativeAudioPlugin()

        XCTAssertEqual(plugin.jsName, "NativeAudio")
        XCTAssertEqual(plugin.pluginMethods.map(\.name), [
            "initialize", "load", "play", "pause", "toggle", "seek", "next", "previous",
            "setQueue", "updateQueue", "setVolume", "setReplayGainMode", "setReplayGainPreamp",
            "setEQEnabled", "setEQBands", "getState", "getDiagnostics"
        ])
    }

    func testPublishesVersionedBridgeEventsForChangedState() throws {
        let harness = try CoordinatorHarness()
        let delegate = RecordingCoordinatorDelegate()
        harness.coordinator.delegate = delegate
        _ = try harness.initialize().get()

        let loaded = try harness.load(harness.a).get()
        let publication = try XCTUnwrap(delegate.publications.last)

        XCTAssertEqual(publication.snapshot.version, loaded.version)
        XCTAssertEqual(Set(publication.events), [
            .stateChanged, .trackChanged, .queueChanged, .formatChanged
        ])

        harness.coordinator.beginInterruption()
        _ = try harness.state()
        XCTAssertTrue(delegate.publications.last?.events.contains(.interruptionChanged) == true)
    }

    func testPlayIsIdempotentAndPauseChangesUserIntent() throws {
        let harness = try CoordinatorHarness()
        _ = try harness.initialize().get()
        _ = try harness.load(harness.a).get()

        let first = try harness.command(harness.coordinator.play).get()
        let second = try harness.command(harness.coordinator.play).get()
        XCTAssertEqual(harness.scheduler.playCallCount, 1)
        XCTAssertEqual(first.version, second.version)
        XCTAssertEqual(second.intent, .playing)

        let paused = try harness.command(harness.coordinator.pause).get()
        XCTAssertEqual(paused.intent, .paused)
        XCTAssertFalse(harness.scheduler.isPlaying)
        XCTAssertEqual(paused.version, first.version + 1)
    }

    func testFailedPlayDoesNotChangeUserIntent() throws {
        let harness = try CoordinatorHarness()
        _ = try harness.initialize().get()
        _ = try harness.load(harness.a).get()
        harness.scheduler.playError = .operation(trackID: "A", reason: "start failed")

        let result = harness.command(harness.coordinator.play)

        XCTAssertEqual(result.failure?.code, "media_open_failed")
        XCTAssertEqual(try harness.state().intent, .paused)
        XCTAssertFalse(harness.scheduler.isPlaying)
    }

    func testLateLoadCompletionCannotReplaceNewerTrack() throws {
        let media = ControlledMediaInfo()
        let harness = try CoordinatorHarness(mediaInfo: media)
        _ = try harness.initialize().get()
        let inspections = expectation(description: "both media inspections begin")
        inspections.expectedFulfillmentCount = 2
        media.onInspect = { inspections.fulfill() }
        let stale = expectation(description: "stale load completes")
        let current = expectation(description: "current load completes")
        var staleResult: Result<PlaybackSnapshot, PlaybackFailure>?
        var currentResult: Result<PlaybackSnapshot, PlaybackFailure>?

        harness.coordinator.load(trackID: "A", mediaRef: harness.a.mediaRef) { staleResult = $0; stale.fulfill() }
        harness.coordinator.load(trackID: "B", mediaRef: harness.b.mediaRef) { currentResult = $0; current.fulfill() }
        wait(for: [inspections], timeout: 1)
        media.complete(trackID: "A", with: .success(harness.source))
        media.complete(trackID: "B", with: .success(harness.source))
        wait(for: [stale, current], timeout: 1)

        XCTAssertEqual(try currentResult?.get().trackID, "B")
        XCTAssertEqual(staleResult?.failure?.code, "stale_operation")
        XCTAssertEqual(try harness.state().trackID, "B")
        XCTAssertEqual(harness.scheduler.preparedTrackIDs, ["B"])
    }

    func testInterruptionNeverOverwritesUserIntent() throws {
        let harness = try CoordinatorHarness()
        _ = try harness.initialize().get()
        _ = try harness.load(harness.a).get()
        _ = try harness.command(harness.coordinator.play).get()

        harness.coordinator.beginInterruption()
        XCTAssertEqual(try harness.state().intent, .playing)
        XCTAssertFalse(harness.scheduler.isPlaying)
        XCTAssertEqual(harness.scheduler.pauseCallCount, 1)

        harness.coordinator.endInterruption(systemAllowsResume: false)
        XCTAssertEqual(try harness.state().intent, .playing)
        XCTAssertFalse(harness.scheduler.isPlaying)

        harness.coordinator.beginInterruption()
        harness.coordinator.endInterruption(systemAllowsResume: true)
        XCTAssertEqual(try harness.state().intent, .playing)
        XCTAssertTrue(harness.scheduler.isPlaying)
        XCTAssertEqual(harness.scheduler.playCallCount, 2)
    }

    func testVisibleMutationsIncrementAndPersistStateVersion() throws {
        let harness = try CoordinatorHarness()
        var versions: [UInt64] = []
        versions.append(try harness.initialize().get().version)
        versions.append(try harness.load(harness.a).get().version)
        versions.append(try harness.command(harness.coordinator.play).get().version)
        versions.append(try harness.command { harness.coordinator.seek(seconds: 0.01, completion: $0) }.get().version)
        versions.append(try harness.command { harness.coordinator.setVolume(0.5, completion: $0) }.get().version)
        versions.append(try harness.command {
            harness.coordinator.setEQ(
                enabled: true,
                bands: [EQBand(frequency: 1_000, q: 1, gainDB: -2)],
                completion: $0
            )
        }.get().version)

        XCTAssertEqual(versions, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(harness.store.saved.map(\.version), versions)
        let noOp = try harness.command { harness.coordinator.setVolume(0.5, completion: $0) }.get()
        XCTAssertEqual(noOp.version, 6)
        XCTAssertEqual(harness.store.saved.count, 6)
    }

    func testNewQueueRevisionInvalidatesPreparedNextAndRejectsStaleRevision() throws {
        let harness = try CoordinatorHarness()
        _ = try harness.initialize().get()
        _ = try harness.load(harness.a, queue: [harness.a, harness.b], index: 0).get()
        let oldGeneration = harness.scheduler.currentGeneration

        let changed = try harness.command {
            harness.coordinator.setQueue(items: [harness.a, harness.c], index: 0, revision: 2, completion: $0)
        }.get()
        XCTAssertEqual(changed.queueRevision, 2)
        XCTAssertEqual(harness.scheduler.replaceQueueCallCount, 1)
        XCTAssertGreaterThan(harness.scheduler.currentGeneration, oldGeneration)

        let stale = harness.command {
            harness.coordinator.setQueue(items: [harness.a, harness.b], index: 0, revision: 1, completion: $0)
        }
        XCTAssertEqual(stale.failure?.code, "queue_revision_stale")
        XCTAssertEqual(harness.scheduler.replaceQueueCallCount, 1)

        harness.scheduler.emit(.handoff(
            fromTrackID: "A", toTrackID: "B", index: 1,
            token: ScheduleToken(generation: oldGeneration)
        ))
        XCTAssertEqual(try harness.state().trackID, "A")
    }

    func testInitializeRestoresCheckpointWithoutAutoplay() throws {
        let restored = PlaybackSnapshot(
            version: 12,
            trackID: "A",
            queueRevision: 4,
            queue: [QueueItem(trackID: "A", albumID: "album", mediaRef: .native(relativePath: "A.wav"))],
            queueIndex: 0,
            position: 19.5,
            intent: .playing,
            replayGainMode: .album,
            replayGainPreampDB: -1,
            masterVolume: 0.75,
            eqEnabled: false,
            eqBands: [],
            route: nil,
            sourceFormat: nil,
            outputFormat: nil,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let harness = try CoordinatorHarness(restored: restored)

        let initialized = try harness.initialize().get()
        XCTAssertEqual(initialized.version, 13)
        XCTAssertEqual(initialized.trackID, "A")
        XCTAssertEqual(initialized.position, 19.5)
        XCTAssertEqual(initialized.intent, .paused)
        XCTAssertFalse(harness.scheduler.isPlaying)
        XCTAssertEqual(harness.scheduler.playCallCount, 0)
        XCTAssertEqual(harness.graph.masterVolume, 0.75)
    }
}

private final class RecordingCoordinatorDelegate: PlaybackCoordinatorDelegate {
    struct Publication {
        let snapshot: PlaybackSnapshot
        let events: [PlaybackCoordinatorEvent]
    }

    private(set) var publications: [Publication] = []

    func playbackCoordinator(
        _ coordinator: PlaybackCoordinator,
        didPublish snapshot: PlaybackSnapshot,
        events: [PlaybackCoordinatorEvent]
    ) {
        publications.append(Publication(snapshot: snapshot, events: events))
    }

    func playbackCoordinator(
        _ coordinator: PlaybackCoordinator,
        didFail failure: PlaybackFailure,
        version: UInt64
    ) {}
}

private final class CoordinatorHarness {
    let a = QueueItem(trackID: "A", albumID: "album", mediaRef: .native(relativePath: "A.wav"))
    let b = QueueItem(trackID: "B", albumID: "album", mediaRef: .native(relativePath: "B.wav"))
    let c = QueueItem(trackID: "C", albumID: "album", mediaRef: .native(relativePath: "C.wav"))
    let source = SourceFormatDescriptor(codec: "pcm", container: "wav", sampleRate: 48_000, channelCount: 2, bitDepth: 16, duration: 1)
    let scheduler = CoordinatorScheduler()
    let graph = CoordinatorGraph()
    let store: MemoryStateStore
    let coordinator: PlaybackCoordinator

    init(restored: PlaybackSnapshot? = nil, mediaInfo: PlaybackMediaInfoProviding? = nil) throws {
        store = MemoryStateStore(restored: restored)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let diagnostics = DiagnosticsLog(url: root.appendingPathComponent("diagnostics.jsonl"))
        coordinator = PlaybackCoordinator(
            scheduler: scheduler,
            graph: graph,
            stateStore: store,
            diagnostics: diagnostics,
            mediaInfo: mediaInfo ?? ImmediateMediaInfo(),
            now: { Date(timeIntervalSince1970: 200) }
        )
    }

    func initialize() -> Result<PlaybackSnapshot, PlaybackFailure> {
        command(coordinator.initialize)
    }

    func load(_ item: QueueItem, queue: [QueueItem]? = nil, index: Int? = nil) -> Result<PlaybackSnapshot, PlaybackFailure> {
        command { coordinator.load(trackID: item.trackID, mediaRef: item.mediaRef, queue: queue, index: index, completion: $0) }
    }

    func command(_ invoke: (@escaping PlaybackCommandCompletion) -> Void) -> Result<PlaybackSnapshot, PlaybackFailure> {
        let completed = XCTestExpectation(description: "coordinator command")
        var result: Result<PlaybackSnapshot, PlaybackFailure>?
        invoke { result = $0; completed.fulfill() }
        XCTWaiter().wait(for: [completed], timeout: 2)
        return result ?? .failure(PlaybackFailure(code: "test_timeout", message: "Command timed out", recoverable: false, trackID: nil))
    }

    func state() throws -> PlaybackSnapshot {
        let completed = XCTestExpectation(description: "coordinator state")
        var snapshot: PlaybackSnapshot?
        coordinator.getState { snapshot = $0; completed.fulfill() }
        XCTWaiter().wait(for: [completed], timeout: 2)
        return try XCTUnwrap(snapshot)
    }
}

private final class CoordinatorScheduler: PlaybackScheduling {
    var onEvent: ((SchedulerEvent) -> Void)?
    private(set) var currentGeneration: UInt64 = 0
    private(set) var queueRevision: UInt64 = 0
    private(set) var queueItems: [QueueItem] = []
    private(set) var currentIndex: Int?
    var currentTrackID: String? { currentIndex.map { queueItems[$0].trackID } }
    private(set) var currentPosition: Double = 0
    private(set) var currentSlot: AudioSlot = .a
    private(set) var isPlaying = false
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var replaceQueueCallCount = 0
    private(set) var preparedTrackIDs: [String] = []
    var playError: QueueSchedulerError?

    func setQueue(_ items: [QueueItem], index: Int, revision: UInt64) throws {
        try validate(items, index)
        advance()
        queueItems = items
        currentIndex = items.isEmpty ? nil : index
        queueRevision = revision
        currentPosition = 0
        isPlaying = false
    }

    func prepareCurrent(position: Double) throws {
        guard position.isFinite, position >= 0, let currentTrackID else { throw QueueSchedulerError.invalidPosition }
        advance()
        currentPosition = position
        preparedTrackIDs.append(currentTrackID)
    }

    func play() throws {
        if let playError { throw playError }
        guard currentIndex != nil else { throw QueueSchedulerError.emptyQueue }
        guard !isPlaying else { return }
        playCallCount += 1
        isPlaying = true
    }

    func pause() {
        pauseCallCount += 1
        isPlaying = false
        advance()
    }

    func seek(seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0 else { throw QueueSchedulerError.invalidPosition }
        currentPosition = seconds
        advance()
    }

    func next() throws { try move(1) }
    func previous() throws { try move(-1) }

    func replaceQueue(_ items: [QueueItem], index: Int, revision: UInt64) throws {
        try validate(items, index)
        replaceQueueCallCount += 1
        queueItems = items
        currentIndex = items.isEmpty ? nil : index
        queueRevision = revision
        advance()
    }

    func invalidatePendingSchedule() {
        isPlaying = false
        advance()
    }

    func emit(_ event: SchedulerEvent) { onEvent?(event) }

    private func move(_ offset: Int) throws {
        guard let currentIndex else { throw QueueSchedulerError.emptyQueue }
        let next = currentIndex + offset
        guard queueItems.indices.contains(next) else { return }
        self.currentIndex = next
        currentPosition = 0
        currentSlot = currentSlot == .a ? .b : .a
        advance()
    }

    private func validate(_ items: [QueueItem], _ index: Int) throws {
        guard (items.isEmpty && index == 0) || items.indices.contains(index) else {
            throw QueueSchedulerError.invalidQueueIndex(index)
        }
    }

    private func advance() { currentGeneration &+= 1 }
}

private final class CoordinatorGraph: PlaybackGraphControlling {
    private(set) var masterVolume: Float = 1
    private(set) var replayGain: [AudioSlot: Float] = [:]
    private(set) var eqEnabled = false
    private(set) var eqBands: [EQBand] = []

    func setMasterVolume(_ linear: Float) { masterVolume = linear }
    func setReplayGain(_ scalar: Float, slot: AudioSlot) { replayGain[slot] = scalar }
    func setEQ(enabled: Bool, bands: [EQBand]) throws { eqEnabled = enabled; eqBands = bands }
    func outputDescriptor() -> OutputFormatDescriptor {
        let route = RouteDescriptor(kind: .speaker, name: "Speaker", sampleRate: 48_000, channelCount: 2)
        return OutputFormatDescriptor(sampleRate: 48_000, channelCount: 2, route: route)
    }
}

private final class MemoryStateStore: PlaybackStatePersisting {
    let restored: PlaybackSnapshot?
    private(set) var saved: [PlaybackSnapshot] = []
    init(restored: PlaybackSnapshot?) { self.restored = restored }
    func save(_ snapshot: PlaybackSnapshot) throws { saved.append(snapshot) }
    func load() -> PlaybackSnapshot? { restored }
}

private final class ImmediateMediaInfo: PlaybackMediaInfoProviding {
    func inspect(
        trackID: String,
        reference: MediaReference,
        completion: @escaping (Result<SourceFormatDescriptor?, PlaybackFailure>) -> Void
    ) {
        completion(.success(SourceFormatDescriptor(
            codec: "pcm", container: "wav", sampleRate: 48_000,
            channelCount: 2, bitDepth: 16, duration: 1
        )))
    }
}

private final class ControlledMediaInfo: PlaybackMediaInfoProviding {
    var onInspect: (() -> Void)?
    private let lock = NSLock()
    private var pending: [String: (Result<SourceFormatDescriptor?, PlaybackFailure>) -> Void] = [:]

    func inspect(
        trackID: String,
        reference: MediaReference,
        completion: @escaping (Result<SourceFormatDescriptor?, PlaybackFailure>) -> Void
    ) {
        lock.lock()
        pending[trackID] = completion
        lock.unlock()
        onInspect?()
    }

    func complete(trackID: String, with result: Result<SourceFormatDescriptor?, PlaybackFailure>) {
        lock.lock()
        let completion = pending.removeValue(forKey: trackID)
        lock.unlock()
        completion?(result)
    }
}

private extension Result where Failure == PlaybackFailure {
    var failure: PlaybackFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private extension Optional where Wrapped == Result<PlaybackSnapshot, PlaybackFailure> {
    var failure: PlaybackFailure? {
        guard case .failure(let failure)? = self else { return nil }
        return failure
    }
}
