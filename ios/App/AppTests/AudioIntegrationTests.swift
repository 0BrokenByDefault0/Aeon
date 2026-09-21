import XCTest
@testable import App

final class AudioIntegrationTests: XCTestCase {
    func testMixedRatesAndExactPCMBoundariesShareOneContiguousTimeline() throws {
        let graph = IntegrationGraph(files: [
            "rate-44.wav": ScheduledAudioFile(frameCount: 44_100, sampleRate: 44_100),
            "rate-96.wav": ScheduledAudioFile(frameCount: 96_000, sampleRate: 96_000),
            "rate-48.wav": ScheduledAudioFile(frameCount: 48_000, sampleRate: 48_000)
        ])
        let scheduler = makeScheduler(graph: graph)
        let items = [item("rate-44"), item("rate-96"), item("rate-48")]

        try scheduler.setQueue(items, index: 0, revision: 1)
        try scheduler.prepareCurrent(position: 0)
        try scheduler.play()

        XCTAssertEqual(graph.schedules.map(\.outputFrame), [0, 48_000])
        graph.schedules[0].completion()
        XCTAssertEqual(scheduler.currentTrackID, "rate-96")
        XCTAssertEqual(graph.schedules.map(\.outputFrame), [0, 48_000, 96_000])
        XCTAssertEqual(
            try QueueScheduler.outputBoundary(start: 2_400, sourceFrames: 2_400, sourceRate: 48_000, outputRate: 48_000),
            4_800
        )
    }

    func testCompressedSeekToleranceAndQueueReplacementPreserveTheSelectedTrack() throws {
        let graph = IntegrationGraph(files: [
            "current.m4a": ScheduledAudioFile(frameCount: 441_000, sampleRate: 44_100),
            "old-next.m4a": ScheduledAudioFile(frameCount: 480_000, sampleRate: 48_000),
            "new-next.m4a": ScheduledAudioFile(frameCount: 960_000, sampleRate: 96_000)
        ])
        let scheduler = makeScheduler(graph: graph)
        let current = item("current", extension: "m4a")
        let oldNext = item("old-next", extension: "m4a")
        let newNext = item("new-next", extension: "m4a")
        try scheduler.setQueue([current, oldNext], index: 0, revision: 1)
        try scheduler.prepareCurrent(position: 0)
        try scheduler.play()

        let requested = 3.14159
        try scheduler.seek(seconds: requested)
        let expectedFrame = Int64((requested * 44_100).rounded(.down))
        XCTAssertEqual(graph.schedules.suffix(2).first?.sourceFrame, expectedFrame)
        XCTAssertEqual(scheduler.currentPosition, Double(expectedFrame) / 44_100, accuracy: 1 / 44_100)

        try scheduler.replaceQueue([current, newNext], index: 0, revision: 2)
        XCTAssertEqual(scheduler.currentTrackID, current.trackID)
        XCTAssertEqual(scheduler.queueItems, [current, newNext])
        XCTAssertEqual(scheduler.queueRevision, 2)
        XCTAssertEqual(graph.closedSlots.count, 3, "Seek closes both slots; upcoming replacement closes only the alternate")
        XCTAssertEqual(scheduler.preparedNextTrackID, newNext.trackID)
    }

    func testActualSchedulerCoordinatorRepeatAndEOFMatrix() throws {
        for mode: RepeatMode in [.off, .all, .one] {
            let graph = IntegrationGraph(files: [
                "first.wav": ScheduledAudioFile(frameCount: 48000, sampleRate: 48000),
                "last.wav": ScheduledAudioFile(frameCount: 48000, sampleRate: 48000)
            ])
            let scheduler = makeScheduler(graph: graph)
            let coordinator = PlaybackCoordinator(
                scheduler: scheduler, graph: graph, stateStore: IntegrationStateStore(restored: nil),
                diagnostics: DiagnosticsLog(url: temporaryDiagnosticsURL()), mediaInfo: IntegrationMediaInfo())
            _ = try result(from: coordinator.initialize)
            let queue = [item("first"), item("last")]
            _ = try result { coordinator.load(trackID: "last", mediaRef: queue[1].mediaRef,
                                              queue: queue, index: 1, completion: $0) }
            _ = try result(from: coordinator.play)
            graph.elapsedFrames = 12000
            let observed = expectation(description: "mid-track observation")
            coordinator.getState { state in
                XCTAssertEqual(state.position, 0.25, accuracy: 0.000001)
                observed.fulfill()
            }
            wait(for: [observed], timeout: 2)
            let starts = graph.startCount
            let changed = try result { coordinator.setRepeatMode(mode, completion: $0) }
            XCTAssertEqual(changed.position, 0.25, accuracy: 0.000001)
            XCTAssertEqual(graph.startCount, starts)
            XCTAssertEqual(changed.trackID, "last")
            let observer = IntegrationObserver()
            coordinator.delegate = observer
            let completed = expectation(description: "completion resolves \(mode)")
            observer.onSnapshot = { state in
                if mode == .off && state.intent == .paused || mode != .off && state.position == 0 {
                    observer.onSnapshot = nil
                    completed.fulfill()
                }
            }
            graph.elapsedFrames = 48000
            graph.schedules.last!.completion()
            wait(for: [completed], timeout: 2)
            let refreshed = expectation(description: "observational EOF refresh")
            coordinator.getState { state in
                XCTAssertEqual(state.trackID, mode == .all ? "first" : "last")
                XCTAssertEqual(state.queueIndex, mode == .all ? 0 : 1)
                XCTAssertEqual(state.intent, mode == .off ? .paused : .playing)
                XCTAssertEqual(state.position, mode == .off ? 1 : 0, accuracy: 0.000001)
                refreshed.fulfill()
            }
            wait(for: [refreshed], timeout: 2)
            XCTAssertTrue(observer.failures.isEmpty)
            if mode != .off { XCTAssertEqual(graph.schedules.last?.sourceFrame, 0) }
        }
    }

    func testRestoreNeverAutoplaysAndEveryUnplayableClassRemainsExplicit() throws {
        let restored = PlaybackSnapshot(
            version: 8,
            trackID: "restore",
            queueRevision: 3,
            queue: [item("restore")],
            queueIndex: 0,
            position: 0.25,
            intent: .playing,
            replayGainMode: .off,
            replayGainPreampDB: 0,
            masterVolume: 0.8,
            eqEnabled: false,
            eqBands: [],
            route: nil,
            sourceFormat: nil,
            outputFormat: nil,
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let graph = IntegrationGraph(files: [
            "restore.wav": ScheduledAudioFile(frameCount: 48_000, sampleRate: 48_000)
        ])
        let scheduler = makeScheduler(graph: graph)
        let coordinator = PlaybackCoordinator(
            scheduler: scheduler,
            graph: graph,
            stateStore: IntegrationStateStore(restored: restored),
            diagnostics: DiagnosticsLog(url: temporaryDiagnosticsURL()),
            mediaInfo: IntegrationMediaInfo(),
            callbackQueue: DispatchQueue(label: "app.aeon.tests.audio-callback")
        )
        let initialized = try result(from: coordinator.initialize)

        XCTAssertEqual(initialized.trackID, "restore")
        XCTAssertEqual(initialized.intent, .paused)
        XCTAssertEqual(initialized.position, 0.25, accuracy: 1 / 48_000)
        XCTAssertFalse(scheduler.isPlaying)
        XCTAssertEqual(graph.startCount, 0)

        let capabilities: [MediaCapability] = [
            .unavailable,
            .decodeFailed(reason: "corrupt"),
            .unsupported(reason: "unsupported")
        ]
        for (index, capability) in capabilities.enumerated() {
            let failingGraph = IntegrationGraph(files: [
                "failure-\(index).wav": ScheduledAudioFile(frameCount: 48_000, sampleRate: 48_000)
            ])
            let failingScheduler = QueueScheduler(
                graph: failingGraph,
                resolver: IntegrationResolver(),
                probe: { _ in capability }
            )
            let failedItem = item("failure-\(index)")
            try failingScheduler.setQueue([failedItem], index: 0, revision: 1)
            XCTAssertThrowsError(try failingScheduler.prepareCurrent(position: 0)) { error in
                XCTAssertEqual(error as? QueueSchedulerError, .media(trackID: failedItem.trackID, capability: capability))
            }
            XCTAssertFalse(failingScheduler.isPlaying)
        }
    }

    func testRecoveryEscalatesThroughNodeEngineAndSessionBeforeResuming() throws {
        let graph = IntegrationGraph(files: [
            "recover.wav": ScheduledAudioFile(frameCount: 48_000, sampleRate: 48_000)
        ])
        let scheduler = makeScheduler(graph: graph)
        let session = IntegrationSession()
        try scheduler.setQueue([item("recover")], index: 0, revision: 1)
        graph.remainingOpenFailures = 2
        let recovery = RecoveryCoordinator(scheduler: scheduler, graph: graph, session: session)

        let result = try recovery.recover(
            from: .node,
            checkpoint: PlaybackRecoveryCheckpoint(position: 0.5, userIntent: .playing)
        )

        XCTAssertEqual(result, RecoveryResult(level: .session, resumed: true))
        XCTAssertEqual(graph.rebuildCount, 2)
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertTrue(scheduler.isPlaying)
        XCTAssertEqual(scheduler.currentPosition, 0.5, accuracy: 1 / 48_000)
    }

    private func makeScheduler(graph: IntegrationGraph) -> QueueScheduler {
        QueueScheduler(graph: graph, resolver: IntegrationResolver()) { url in
            guard let file = graph.files[url.lastPathComponent] else { return .unavailable }
            return .playable(ProbedMedia(
                url: url,
                descriptor: SourceFormatDescriptor(
                    codec: url.pathExtension == "m4a" ? "aac" : "pcm_s16le",
                    container: url.pathExtension,
                    sampleRate: file.sampleRate,
                    channelCount: 2,
                    bitDepth: url.pathExtension == "wav" ? 16 : nil,
                    duration: Double(file.frameCount) / file.sampleRate
                ),
                frameCount: file.frameCount
            ))
        }
    }

    private func item(_ id: String, extension fileExtension: String = "wav") -> QueueItem {
        QueueItem(trackID: id, albumID: "integration", mediaRef: .native(relativePath: "\(id).\(fileExtension)"))
    }

    private func result(
        from operation: (@escaping PlaybackCommandCompletion) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PlaybackSnapshot {
        let completed = expectation(description: "playback operation")
        var received: Result<PlaybackSnapshot, PlaybackFailure>?
        operation { value in received = value; completed.fulfill() }
        wait(for: [completed], timeout: 2)
        return try XCTUnwrap(received, file: file, line: line).get()
    }

    private func temporaryDiagnosticsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AeonAudioIntegration-\(UUID().uuidString).jsonl", isDirectory: false)
    }
}

private enum IntegrationFailure: Error { case open }

private final class IntegrationResolver: MediaResolving {
    func resolve(_ reference: MediaReference) throws -> URL {
        guard case .native(let path) = reference else { throw MediaStoreError.unavailable(trackID: "integration") }
        return URL(fileURLWithPath: "/integration/\(path)")
    }

    func release(_ url: URL) {}
}

private final class IntegrationGraph: QueueSchedulingGraph, PlaybackGraphControlling {
    struct Schedule {
        let slot: AudioSlot
        let sourceFrame: Int64
        let outputFrame: Int64
        let completion: () -> Void
    }

    let files: [String: ScheduledAudioFile]
    var schedules: [Schedule] = []
    var remainingOpenFailures = 0
    var rebuildCount = 0
    var startCount = 0
    var closedSlots: [AudioSlot] = []
    var elapsedFrames: Int64 = 0
    private var started = false

    init(files: [String: ScheduledAudioFile]) { self.files = files }

    func schedulingSampleRate() throws -> Double { 48_000 }

    func openForScheduling(url: URL, slot: AudioSlot) throws -> ScheduledAudioFile {
        if remainingOpenFailures > 0 {
            remainingOpenFailures -= 1
            throw IntegrationFailure.open
        }
        guard let file = files[url.lastPathComponent] else { throw IntegrationFailure.open }
        return file
    }

    func schedule(
        slot: AudioSlot,
        sourceFrame: Int64,
        outputFrame: Int64,
        completion: @escaping () -> Void
    ) throws {
        schedules.append(Schedule(slot: slot, sourceFrame: sourceFrame, outputFrame: outputFrame, completion: completion))
    }

    func startScheduledPlayback() throws { started = true; startCount += 1 }
    func elapsedSourceFrames(slot: AudioSlot) -> Int64? { elapsedFrames }
    func cancelScheduledPlayback() { started = false; elapsedFrames = 0 }
    func closeScheduledFile(slot: AudioSlot) { closedSlots.append(slot) }
    func setReplayGain(_ scalar: Float, slot: AudioSlot) {}
    func setMasterVolume(_ linear: Float) {}
    func setEQ(enabled: Bool, bands: [EQBand]) throws {}
    func outputDescriptor() -> OutputFormatDescriptor {
        OutputFormatDescriptor(
            sampleRate: 48_000,
            channelCount: 2,
            route: RouteDescriptor(kind: .speaker, name: "Integration output", sampleRate: 48_000, channelCount: 2)
        )
    }
    func rebuild() throws { rebuildCount += 1 }
}

private final class IntegrationStateStore: PlaybackStatePersisting {
    private let restored: PlaybackSnapshot?
    init(restored: PlaybackSnapshot?) { self.restored = restored }
    func save(_ snapshot: PlaybackSnapshot) throws {}
    func load() -> PlaybackSnapshot? { restored }
}

private final class IntegrationMediaInfo: PlaybackMediaInfoProviding {
    func inspect(
        trackID: String,
        reference: MediaReference,
        completion: @escaping (Result<SourceFormatDescriptor?, PlaybackFailure>) -> Void
    ) {
        completion(.success(nil))
    }
}

private final class IntegrationSession: AudioSessionActivating {
    var activateCount = 0
    func activate() throws { activateCount += 1 }
}

private final class IntegrationObserver: PlaybackCoordinatorDelegate {
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    var failures: [PlaybackFailure] = []
    func playbackCoordinator(_ coordinator: PlaybackCoordinator, didPublish snapshot: PlaybackSnapshot,
                             events: [PlaybackCoordinatorEvent]) { onSnapshot?(snapshot) }
    func playbackCoordinator(_ coordinator: PlaybackCoordinator, didFail failure: PlaybackFailure,
                             version: UInt64) { failures.append(failure) }
}
