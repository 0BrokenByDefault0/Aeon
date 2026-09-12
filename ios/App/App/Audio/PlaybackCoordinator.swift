import Foundation

typealias PlaybackCommandCompletion = (Result<PlaybackSnapshot, PlaybackFailure>) -> Void

protocol PlaybackCoordinatorDelegate: AnyObject {
    func playbackCoordinator(_ coordinator: PlaybackCoordinator, didPublish snapshot: PlaybackSnapshot)
    func playbackCoordinator(_ coordinator: PlaybackCoordinator, didFail failure: PlaybackFailure, version: UInt64)
}

extension PlaybackCoordinatorDelegate {
    func playbackCoordinator(_ coordinator: PlaybackCoordinator, didFail failure: PlaybackFailure, version: UInt64) {}
}

protocol PlaybackScheduling: AnyObject {
    var onEvent: ((SchedulerEvent) -> Void)? { get set }
    var currentGeneration: UInt64 { get }
    var queueRevision: UInt64 { get }
    var queueItems: [QueueItem] { get }
    var currentIndex: Int? { get }
    var currentTrackID: String? { get }
    var currentPosition: Double { get }
    var currentSlot: AudioSlot { get }
    var isPlaying: Bool { get }

    func setQueue(_ items: [QueueItem], index: Int, revision: UInt64) throws
    func prepareCurrent(position: Double) throws
    func play() throws
    func pause()
    func seek(seconds: Double) throws
    func next() throws
    func previous() throws
    func replaceQueue(_ items: [QueueItem], index: Int, revision: UInt64) throws
    func invalidatePendingSchedule()
}

extension QueueScheduler: PlaybackScheduling {}

protocol PlaybackGraphControlling: AnyObject {
    func setMasterVolume(_ linear: Float)
    func setReplayGain(_ scalar: Float, slot: AudioSlot)
    func setEQ(enabled: Bool, bands: [EQBand]) throws
    func outputDescriptor() -> OutputFormatDescriptor
}

extension AudioEngineGraph: PlaybackGraphControlling {}

protocol PlaybackStatePersisting: AnyObject {
    func save(_ snapshot: PlaybackSnapshot) throws
    func load() -> PlaybackSnapshot?
}

extension PlaybackStateStore: PlaybackStatePersisting {}

protocol PlaybackMediaInfoProviding: AnyObject {
    func inspect(
        trackID: String,
        reference: MediaReference,
        completion: @escaping (Result<SourceFormatDescriptor?, PlaybackFailure>) -> Void
    )
}

final class NativePlaybackMediaInfoProvider: PlaybackMediaInfoProviding {
    private let resolver: MediaResolving
    private let probe: MetadataProbe
    private let workQueue: DispatchQueue

    init(
        resolver: MediaResolving,
        probe: MetadataProbe = MetadataProbe(),
        workQueue: DispatchQueue = DispatchQueue(label: "app.aeon.audio.media-info", qos: .userInitiated)
    ) {
        self.resolver = resolver
        self.probe = probe
        self.workQueue = workQueue
    }

    func inspect(
        trackID: String,
        reference: MediaReference,
        completion: @escaping (Result<SourceFormatDescriptor?, PlaybackFailure>) -> Void
    ) {
        workQueue.async { [resolver, probe] in
            let url: URL
            do {
                url = try resolver.resolve(reference)
            } catch {
                completion(.failure(Self.failure(for: error, trackID: trackID)))
                return
            }
            defer { resolver.release(url) }
            switch probe.probe(url: url) {
            case .playable(let media):
                completion(.success(media.descriptor))
            case .unsupported(let reason):
                completion(.failure(PlaybackFailure(
                    code: "format_unsupported", message: reason, recoverable: true, trackID: trackID
                )))
            case .decodeFailed(let reason):
                completion(.failure(PlaybackFailure(
                    code: "decoder_error", message: reason, recoverable: true, trackID: trackID
                )))
            case .unavailable:
                completion(.failure(PlaybackFailure(
                    code: "media_missing", message: "File unavailable", recoverable: true, trackID: trackID
                )))
            }
        }
    }

    private static func failure(for error: Error, trackID: String) -> PlaybackFailure {
        switch error {
        case MediaStoreError.migrationRequired:
            return PlaybackFailure(code: "migration_required", message: "Media migration required", recoverable: true, trackID: trackID)
        case MediaStoreError.staleBookmark, MediaStoreError.invalidBookmark, MediaStoreError.securityScopedAccessDenied:
            return PlaybackFailure(code: "media_permission", message: "File permission unavailable", recoverable: true, trackID: trackID)
        default:
            return PlaybackFailure(code: "media_open_failed", message: "Could not open media", recoverable: true, trackID: trackID)
        }
    }
}

final class PlaybackCoordinator {
    weak var delegate: PlaybackCoordinatorDelegate?

    private let scheduler: PlaybackScheduling
    private let graph: PlaybackGraphControlling
    private let stateStore: PlaybackStatePersisting
    private let diagnostics: DiagnosticsLog
    private let mediaInfo: PlaybackMediaInfoProviding
    private let transportQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let now: () -> Date
    private var versionClock: StateVersionClock
    private var initialized = false
    private var operationGeneration: UInt64 = 0
    private var acceptedSchedulerGeneration: UInt64 = 0
    private var interruptionActive = false

    private var version: UInt64
    private var trackID: String?
    private var queueRevision: UInt64
    private var queue: [QueueItem]
    private var queueIndex: Int?
    private var position: Double
    private var intent: PlaybackIntent
    private var replayGainMode: ReplayGainMode
    private var replayGainPreampDB: Double
    private var masterVolume: Double
    private var eqEnabled: Bool
    private var eqBands: [EQBand]
    private var route: RouteDescriptor?
    private var sourceFormat: SourceFormatDescriptor?
    private var outputFormat: OutputFormatDescriptor?

    init(
        scheduler: PlaybackScheduling,
        graph: PlaybackGraphControlling,
        stateStore: PlaybackStatePersisting,
        diagnostics: DiagnosticsLog,
        mediaInfo: PlaybackMediaInfoProviding,
        transportQueue: DispatchQueue = DispatchQueue(label: "app.aeon.audio.transport", qos: .userInitiated),
        callbackQueue: DispatchQueue = .main,
        now: @escaping () -> Date = Date.init
    ) {
        self.scheduler = scheduler
        self.graph = graph
        self.stateStore = stateStore
        self.diagnostics = diagnostics
        self.mediaInfo = mediaInfo
        self.transportQueue = transportQueue
        self.callbackQueue = callbackQueue
        self.now = now

        let restored = stateStore.load()
        version = restored?.version ?? 0
        versionClock = StateVersionClock(seed: version)
        trackID = restored?.trackID
        queueRevision = restored?.queueRevision ?? 0
        queue = restored?.queue ?? []
        queueIndex = restored?.queueIndex
        position = restored?.position ?? 0
        intent = restored?.intent ?? .paused
        replayGainMode = restored?.replayGainMode ?? .off
        replayGainPreampDB = restored?.replayGainPreampDB ?? 0
        masterVolume = restored?.masterVolume ?? 1
        eqEnabled = restored?.eqEnabled ?? false
        eqBands = restored?.eqBands ?? []
        route = restored?.route
        sourceFormat = restored?.sourceFormat
        outputFormat = restored?.outputFormat

        scheduler.onEvent = { [weak self] event in self?.receive(event) }
    }

    convenience init(
        scheduler: QueueScheduler,
        graph: AudioEngineGraph,
        mediaStore: MediaStore,
        stateStore: PlaybackStateStore,
        diagnostics: DiagnosticsLog
    ) {
        self.init(
            scheduler: scheduler,
            graph: graph,
            stateStore: stateStore,
            diagnostics: diagnostics,
            mediaInfo: NativePlaybackMediaInfoProvider(resolver: mediaStore)
        )
    }

    func initialize(completion: @escaping PlaybackCommandCompletion) {
        transportQueue.async { [weak self] in
            guard let self else { return }
            if initialized {
                succeed(currentSnapshot(), completion: completion)
                return
            }
            do {
                if !queue.isEmpty {
                    guard let index = queueIndex, queue.indices.contains(index) else {
                        throw CoordinatorError.invalidQueueIndex
                    }
                    try scheduler.setQueue(queue, index: index, revision: queueRevision)
                    try scheduler.prepareCurrent(position: position)
                    acceptedSchedulerGeneration = scheduler.currentGeneration
                    trackID = scheduler.currentTrackID
                } else {
                    trackID = nil
                    queueIndex = nil
                    position = 0
                }
                graph.setMasterVolume(Float(masterVolume))
                try graph.setEQ(enabled: eqEnabled, bands: eqBands)
                // Relaunch restores continuity but never surprises the user with autoplay.
                intent = .paused
                outputFormat = graph.outputDescriptor()
                route = outputFormat?.route
                initialized = true
                let snapshot = try publish(eventCode: "ENGINE_INITIALIZED")
                succeed(snapshot, completion: completion)
            } catch {
                fail(error, completion: completion)
            }
        }
    }

    func load(
        trackID: String,
        mediaRef: MediaReference,
        queue requestedQueue: [QueueItem]? = nil,
        index requestedIndex: Int? = nil,
        completion: @escaping PlaybackCommandCompletion
    ) {
        transportQueue.async { [weak self] in
            guard let self else { return }
            guard initialized else { fail(CoordinatorError.notInitialized, trackID: trackID, completion: completion); return }
            guard !trackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail(CoordinatorError.invalidTrackID, completion: completion)
                return
            }
            let generation: UInt64
            do { generation = try advanceOperationGeneration() }
            catch { fail(error, trackID: trackID, completion: completion); return }
            mediaInfo.inspect(trackID: trackID, reference: mediaRef) { [weak self] result in
                guard let self else { return }
                self.transportQueue.async {
                    guard generation == self.operationGeneration else {
                        self.deliver(.failure(PlaybackFailure(
                            code: "stale_operation", message: "A newer playback request replaced this load",
                            recoverable: true, trackID: trackID
                        )), completion: completion)
                        return
                    }
                    switch result {
                    case .failure(let failure):
                        self.fail(failure, completion: completion)
                    case .success(let descriptor):
                        self.finishLoad(
                            trackID: trackID, mediaRef: mediaRef, sourceFormat: descriptor,
                            requestedQueue: requestedQueue, requestedIndex: requestedIndex,
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    func play(completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            guard trackID != nil else { throw CoordinatorError.noTrackLoaded }
            if intent == .playing, scheduler.isPlaying {
                return currentSnapshot()
            }
            if !interruptionActive { try scheduler.play() }
            intent = .playing
            acceptedSchedulerGeneration = scheduler.currentGeneration
            return try publish(eventCode: "PLAYBACK_STARTED")
        }
    }

    func pause(completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            let wasPlaying = scheduler.isPlaying
            if wasPlaying { scheduler.pause() }
            syncSchedulerState()
            if intent == .paused, !wasPlaying { return currentSnapshot() }
            intent = .paused
            acceptedSchedulerGeneration = scheduler.currentGeneration
            return try publish(eventCode: "PLAYBACK_PAUSED")
        }
    }

    func seek(seconds: Double, completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            guard seconds.isFinite, seconds >= 0 else { throw CoordinatorError.invalidPosition }
            try scheduler.seek(seconds: seconds)
            acceptedSchedulerGeneration = scheduler.currentGeneration
            syncSchedulerState()
            return try publish(eventCode: "SEEK")
        }
    }

    func next(completion: @escaping PlaybackCommandCompletion) {
        move(command: scheduler.next, eventCode: "TRACK_NEXT", completion: completion)
    }

    func previous(completion: @escaping PlaybackCommandCompletion) {
        move(command: scheduler.previous, eventCode: "TRACK_PREVIOUS", completion: completion)
    }

    func setQueue(
        items: [QueueItem],
        index: Int,
        revision: UInt64,
        completion: @escaping PlaybackCommandCompletion
    ) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            guard revision > queueRevision else { throw CoordinatorError.staleQueueRevision }
            _ = try advanceOperationGeneration()
            try scheduler.replaceQueue(items, index: index, revision: revision)
            acceptedSchedulerGeneration = scheduler.currentGeneration
            syncSchedulerState()
            sourceFormat = nil
            outputFormat = graph.outputDescriptor()
            route = outputFormat?.route
            return try publish(eventCode: "QUEUE_CHANGED")
        }
    }

    func setVolume(_ value: Float, completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            guard value.isFinite, (0...1).contains(value) else { throw CoordinatorError.invalidVolume }
            let requested = Double(value)
            if masterVolume == requested { return currentSnapshot() }
            graph.setMasterVolume(value)
            masterVolume = requested
            return try publish(eventCode: "VOLUME_CHANGED")
        }
    }

    func setReplayGainMode(_ mode: ReplayGainMode, completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            if replayGainMode == mode { return currentSnapshot() }
            replayGainMode = mode
            applyReplayGain()
            return try publish(eventCode: "REPLAYGAIN_MODE_CHANGED")
        }
    }

    func setReplayGainPreamp(_ db: Double, completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            guard db.isFinite else { throw CoordinatorError.invalidReplayGainPreamp }
            if replayGainPreampDB == db { return currentSnapshot() }
            replayGainPreampDB = db
            applyReplayGain()
            return try publish(eventCode: "REPLAYGAIN_PREAMP_CHANGED")
        }
    }

    func setEQ(enabled: Bool, bands: [EQBand], completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            if eqEnabled == enabled, eqBands == bands { return currentSnapshot() }
            try graph.setEQ(enabled: enabled, bands: bands)
            eqEnabled = enabled
            eqBands = bands
            return try publish(eventCode: "EQ_CHANGED")
        }
    }

    func getState(completion: @escaping (PlaybackSnapshot) -> Void) {
        transportQueue.async { [weak self] in
            guard let self else { return }
            syncSchedulerState()
            let snapshot = currentSnapshot()
            callbackQueue.async { completion(snapshot) }
        }
    }

    func beginInterruption() {
        transportQueue.async { [weak self] in
            guard let self, initialized, !interruptionActive else { return }
            interruptionActive = true
            if scheduler.isPlaying { scheduler.pause() }
            syncSchedulerState()
            acceptedSchedulerGeneration = scheduler.currentGeneration
            _ = try? publish(eventCode: "INTERRUPTION_BEGIN")
        }
    }

    func endInterruption(systemAllowsResume: Bool) {
        transportQueue.async { [weak self] in
            guard let self, initialized, interruptionActive else { return }
            interruptionActive = false
            do {
                if systemAllowsResume, intent == .playing { try scheduler.play() }
                acceptedSchedulerGeneration = scheduler.currentGeneration
                syncSchedulerState()
                _ = try publish(eventCode: "INTERRUPTION_END")
            } catch {
                fail(error, completion: nil)
            }
        }
    }

    private func finishLoad(
        trackID: String,
        mediaRef: MediaReference,
        sourceFormat: SourceFormatDescriptor?,
        requestedQueue: [QueueItem]?,
        requestedIndex: Int?,
        completion: @escaping PlaybackCommandCompletion
    ) {
        do {
            let items: [QueueItem]
            let index: Int
            if let requestedQueue {
                guard let requestedIndex, requestedQueue.indices.contains(requestedIndex),
                      requestedQueue[requestedIndex].trackID == trackID,
                      requestedQueue[requestedIndex].mediaRef == mediaRef else {
                    throw CoordinatorError.invalidQueueContext
                }
                items = requestedQueue
                index = requestedIndex
            } else if let existing = queue.firstIndex(where: { $0.trackID == trackID && $0.mediaRef == mediaRef }) {
                items = queue
                index = existing
            } else {
                items = [QueueItem(trackID: trackID, albumID: "", mediaRef: mediaRef)]
                index = 0
            }
            let revision = try nextQueueRevision()
            try scheduler.setQueue(items, index: index, revision: revision)
            try scheduler.prepareCurrent(position: 0)
            acceptedSchedulerGeneration = scheduler.currentGeneration
            queue = items
            queueIndex = index
            queueRevision = revision
            self.trackID = trackID
            position = 0
            intent = .paused
            self.sourceFormat = sourceFormat
            outputFormat = graph.outputDescriptor()
            route = outputFormat?.route
            let snapshot = try publish(eventCode: "SOURCE_OPENED")
            succeed(snapshot, completion: completion)
        } catch {
            fail(error, trackID: trackID, completion: completion)
        }
    }

    private func move(
        command schedulerCommand: @escaping () throws -> Void,
        eventCode: String,
        completion: @escaping PlaybackCommandCompletion
    ) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            let priorTrack = scheduler.currentTrackID
            try schedulerCommand()
            acceptedSchedulerGeneration = scheduler.currentGeneration
            syncSchedulerState()
            if scheduler.currentTrackID == priorTrack { return currentSnapshot() }
            sourceFormat = nil
            outputFormat = graph.outputDescriptor()
            route = outputFormat?.route
            return try publish(eventCode: eventCode)
        }
    }

    private func command(completion: @escaping PlaybackCommandCompletion, body: @escaping () throws -> PlaybackSnapshot) {
        transportQueue.async { [weak self] in
            guard let self else { return }
            do { succeed(try body(), completion: completion) }
            catch { fail(error, completion: completion) }
        }
    }

    private func receive(_ event: SchedulerEvent) {
        transportQueue.async { [weak self] in
            guard let self else { return }
            let token: ScheduleToken
            switch event {
            case .started(_, _, let value), .handoff(_, _, _, let value), .completed(_, let value), .failed(_, _, let value):
                token = value
            }
            guard token.generation == acceptedSchedulerGeneration else { return }

            switch event {
            case .started:
                return
            case .handoff(_, _, _, _):
                syncSchedulerState()
                sourceFormat = nil
                outputFormat = graph.outputDescriptor()
                route = outputFormat?.route
                _ = try? publish(eventCode: "TRACK_HANDOFF")
            case .completed:
                syncSchedulerState()
                intent = .paused
                _ = try? publish(eventCode: "PLAYBACK_COMPLETED")
            case .failed(let failedTrackID, let error, _):
                syncSchedulerState()
                intent = .paused
                _ = try? publish(eventCode: "PLAYBACK_STOPPED")
                fail(error, trackID: failedTrackID, completion: nil)
            }
        }
    }

    private func syncSchedulerState() {
        queue = scheduler.queueItems
        queueIndex = scheduler.currentIndex
        queueRevision = scheduler.queueRevision
        trackID = scheduler.currentTrackID
        position = scheduler.currentPosition
    }

    private func currentSnapshot() -> PlaybackSnapshot {
        PlaybackSnapshot(
            version: version,
            trackID: trackID,
            queueRevision: queueRevision,
            queue: queue,
            queueIndex: queueIndex,
            position: position,
            intent: intent,
            replayGainMode: replayGainMode,
            replayGainPreampDB: replayGainPreampDB,
            masterVolume: masterVolume,
            eqEnabled: eqEnabled,
            eqBands: eqBands,
            route: route,
            sourceFormat: sourceFormat,
            outputFormat: outputFormat,
            timestamp: now()
        )
    }

    private func publish(eventCode: String) throws -> PlaybackSnapshot {
        guard let nextVersion = versionClock.next() else { throw CoordinatorError.versionExhausted }
        version = nextVersion
        let snapshot = currentSnapshot()
        do {
            try stateStore.save(snapshot)
        } catch {
            try? diagnostics.record(eventCode: "STATE_PERSIST_FAILED", trackID: trackID, recoverable: true)
        }
        try? diagnostics.record(
            eventCode: eventCode,
            trackID: trackID,
            sourceFormat: sourceFormat,
            outputFormat: outputFormat,
            route: route
        )
        callbackQueue.async { [weak self] in
            guard let self else { return }
            delegate?.playbackCoordinator(self, didPublish: snapshot)
        }
        return snapshot
    }

    private func succeed(_ snapshot: PlaybackSnapshot, completion: @escaping PlaybackCommandCompletion) {
        deliver(.success(snapshot), completion: completion)
    }

    private func deliver(_ result: Result<PlaybackSnapshot, PlaybackFailure>, completion: @escaping PlaybackCommandCompletion) {
        callbackQueue.async { completion(result) }
    }

    private func fail(
        _ error: Error,
        trackID: String? = nil,
        completion: PlaybackCommandCompletion?
    ) {
        let failure = (error as? PlaybackFailure) ?? Self.failure(for: error, trackID: trackID ?? self.trackID)
        try? diagnostics.record(eventCode: "PLAYBACK_ERROR", trackID: failure.trackID, recoverable: failure.recoverable)
        callbackQueue.async { [weak self] in
            guard let self else { return }
            delegate?.playbackCoordinator(self, didFail: failure, version: version)
            completion?(.failure(failure))
        }
    }

    @discardableResult
    private func advanceOperationGeneration() throws -> UInt64 {
        guard operationGeneration < .max else { throw CoordinatorError.operationGenerationExhausted }
        operationGeneration += 1
        return operationGeneration
    }

    private func nextQueueRevision() throws -> UInt64 {
        guard queueRevision < .max else { throw CoordinatorError.queueRevisionExhausted }
        return queueRevision + 1
    }

    private func applyReplayGain() {
        let scalar = replayGainScalar(mode: replayGainMode, values: .empty, preampDB: replayGainPreampDB)
        graph.setReplayGain(scalar, slot: .a)
        graph.setReplayGain(scalar, slot: .b)
    }

    private enum CoordinatorError: Error {
        case notInitialized
        case invalidTrackID
        case noTrackLoaded
        case invalidQueueIndex
        case invalidQueueContext
        case staleQueueRevision
        case invalidPosition
        case invalidVolume
        case invalidReplayGainPreamp
        case operationGenerationExhausted
        case queueRevisionExhausted
        case versionExhausted
    }

    private static func failure(for error: Error, trackID: String?) -> PlaybackFailure {
        if let schedulerError = error as? QueueSchedulerError {
            switch schedulerError {
            case .emptyQueue:
                return PlaybackFailure(code: "queue_empty", message: "Queue is empty", recoverable: true, trackID: trackID)
            case .invalidQueueIndex:
                return PlaybackFailure(code: "queue_index_invalid", message: "Queue index is invalid", recoverable: true, trackID: trackID)
            case .invalidPosition:
                return PlaybackFailure(code: "position_invalid", message: "Playback position is invalid", recoverable: true, trackID: trackID)
            case .invalidAudioFormat, .timelineOverflow:
                return PlaybackFailure(code: "audio_format_invalid", message: "Audio timing is invalid", recoverable: false, trackID: trackID)
            case .media(let id, let capability):
                let code: String
                switch capability {
                case .unsupported: code = "format_unsupported"
                case .decodeFailed: code = "decoder_error"
                case .unavailable: code = "media_missing"
                case .playable: code = "media_open_failed"
                }
                return PlaybackFailure(code: code, message: "Media is unavailable", recoverable: true, trackID: id)
            case .operation(let id, _):
                return PlaybackFailure(code: "media_open_failed", message: "Could not prepare media", recoverable: true, trackID: id ?? trackID)
            }
        }
        if error is AudioEngineGraphError {
            return PlaybackFailure(code: "engine_error", message: "Audio engine command failed", recoverable: true, trackID: trackID)
        }
        guard let error = error as? CoordinatorError else {
            return PlaybackFailure(code: "internal_error", message: "Playback command failed", recoverable: false, trackID: trackID)
        }
        switch error {
        case .notInitialized:
            return PlaybackFailure(code: "not_initialized", message: "Native audio is not initialized", recoverable: true, trackID: trackID)
        case .invalidTrackID:
            return PlaybackFailure(code: "track_id_invalid", message: "Track ID is invalid", recoverable: true, trackID: trackID)
        case .noTrackLoaded:
            return PlaybackFailure(code: "track_not_loaded", message: "No track is loaded", recoverable: true, trackID: trackID)
        case .invalidQueueIndex, .invalidQueueContext:
            return PlaybackFailure(code: "queue_invalid", message: "Queue context is invalid", recoverable: true, trackID: trackID)
        case .staleQueueRevision:
            return PlaybackFailure(code: "queue_revision_stale", message: "A newer queue revision is already active", recoverable: true, trackID: trackID)
        case .invalidPosition:
            return PlaybackFailure(code: "position_invalid", message: "Playback position is invalid", recoverable: true, trackID: trackID)
        case .invalidVolume:
            return PlaybackFailure(code: "volume_invalid", message: "Volume must be between zero and one", recoverable: true, trackID: trackID)
        case .invalidReplayGainPreamp:
            return PlaybackFailure(code: "replaygain_preamp_invalid", message: "ReplayGain preamp must be finite", recoverable: true, trackID: trackID)
        case .operationGenerationExhausted:
            return PlaybackFailure(code: "operation_generation_exhausted", message: "Playback command generation exhausted", recoverable: false, trackID: trackID)
        case .queueRevisionExhausted:
            return PlaybackFailure(code: "queue_revision_exhausted", message: "Queue revision exhausted", recoverable: false, trackID: trackID)
        case .versionExhausted:
            return PlaybackFailure(code: "state_version_exhausted", message: "Playback state version exhausted", recoverable: false, trackID: trackID)
        }
    }
}
