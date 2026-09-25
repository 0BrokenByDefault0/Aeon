import Foundation

typealias PlaybackCommandCompletion = (Result<PlaybackSnapshot, PlaybackFailure>) -> Void

enum PlaybackCoordinatorEvent: String {
    case stateChanged
    case positionChanged
    case trackChanged
    case queueChanged
    case routeChanged
    case formatChanged
    case interruptionChanged
    case engineRecovered
    case queueItemSkipped
}

protocol PlaybackCoordinatorDelegate: AnyObject {
    func playbackCoordinator(
        _ coordinator: PlaybackCoordinator,
        didPublish snapshot: PlaybackSnapshot,
        events: [PlaybackCoordinatorEvent]
    )
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
    var currentSourceFormat: SourceFormatDescriptor? { get }
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
    func setReplayGain(mode: ReplayGainMode, preampDB: Double)
    func setRepeatMode(_ mode: RepeatMode) throws
}

extension PlaybackScheduling {
    var currentSourceFormat: SourceFormatDescriptor? { nil }
    func setReplayGain(mode: ReplayGainMode, preampDB: Double) {}
    func setRepeatMode(_ mode: RepeatMode) throws {}
}

extension QueueScheduler: PlaybackScheduling {}

protocol PlaybackGraphControlling: AnyObject {
    func setMasterVolume(_ linear: Float)
    func setReplayGain(_ scalar: Float, slot: AudioSlot)
    func setDSP(_ settings: DSPSettings) throws
    func setEQ(enabled: Bool, bands: [EQBand]) throws
    func outputDescriptor() -> OutputFormatDescriptor
    func rebuild() throws
}

extension PlaybackGraphControlling {
    func setDSP(_ settings: DSPSettings) throws {}
    func rebuild() throws {}
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
        case MediaStoreError.unavailable:
            return PlaybackFailure(code: "media_missing", message: "File unavailable", recoverable: true, trackID: trackID)
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
    private let recovery: PlaybackRecovering?
    private let transportQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let now: () -> Date
    private var listeningRecorder: PlaybackListeningRecorder?
    private var listeningTimer: DispatchSourceTimer?
    private var versionClock: StateVersionClock
    private var initialized = false
    private var operationGeneration: UInt64 = 0
    private var acceptedSchedulerGeneration: UInt64 = 0
    private var interruptionActive = false
    private var lastPublishedSnapshot: PlaybackSnapshot?

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
    private var dsp: DSPSettings
    private var repeatMode: RepeatMode
    private var route: RouteDescriptor?
    private var sourceFormat: SourceFormatDescriptor?
    private var outputFormat: OutputFormatDescriptor?

    init(
        scheduler: PlaybackScheduling,
        graph: PlaybackGraphControlling,
        stateStore: PlaybackStatePersisting,
        diagnostics: DiagnosticsLog,
        mediaInfo: PlaybackMediaInfoProviding,
        recovery: PlaybackRecovering? = nil,
        listeningRepository: CatalogRepository? = nil,
        transportQueue: DispatchQueue = DispatchQueue(label: "app.aeon.audio.transport", qos: .userInitiated),
        callbackQueue: DispatchQueue = .main,
        now: @escaping () -> Date = Date.init
    ) {
        self.scheduler = scheduler
        self.graph = graph
        self.stateStore = stateStore
        self.diagnostics = diagnostics
        self.mediaInfo = mediaInfo
        self.recovery = recovery
        self.transportQueue = transportQueue
        self.callbackQueue = callbackQueue
        self.now = now

        let restored = stateStore.load()
        lastPublishedSnapshot = restored
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
        dsp = restored?.dsp ?? .init()
        dsp.correctionEnabled = false // only an explicitly bound identifiable endpoint may recall
        repeatMode = restored?.repeatMode ?? .off
        route = restored?.route
        sourceFormat = restored?.sourceFormat
        outputFormat = restored?.outputFormat

        scheduler.onEvent = { [weak self] event in self?.receive(event) }
        if let listeningRepository {
            listeningRecorder = PlaybackListeningRecorder(repository: listeningRepository)
            let timer = DispatchSource.makeTimerSource(queue: transportQueue)
            timer.schedule(deadline: .distantFuture, repeating: 5)
            timer.setEventHandler { [weak self] in self?.captureListening() }
            listeningTimer = timer
            timer.resume()
        }
    }

    deinit { listeningTimer?.cancel() }

    /// Drain transport work before storage is moved or closed during an erase.
    func shutdown() {
        transportQueue.sync {
            captureListening()
            try? listeningRecorder?.finish(completed: false)
            listeningTimer?.cancel()
            listeningTimer = nil
            scheduler.pause()
            intent = .paused
            initialized = false
            operationGeneration &+= 1
            try? stateStore.save(currentSnapshot())
        }
    }

    private func captureListening() {
        guard initialized, scheduler.currentTrackID == trackID else { return }
        do {
            try listeningRecorder?.sample(trackID: trackID, queueIndex: queueIndex,
                position: scheduler.currentPosition, duration: sourceFormat?.duration,
                playing: intent == .playing && scheduler.isPlaying)
        } catch {
            try? diagnostics.record(eventCode: "LISTENING_PERSIST_FAILED", trackID: trackID, recoverable: true)
        }
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
                var preparationFailure: Error?
                scheduler.setReplayGain(mode: replayGainMode, preampDB: replayGainPreampDB)
                try scheduler.setRepeatMode(repeatMode)
                if !queue.isEmpty {
                    guard let index = queueIndex, queue.indices.contains(index) else {
                        throw CoordinatorError.invalidQueueIndex
                    }
                    try scheduler.setQueue(queue, index: index, revision: queueRevision)
                    do {
                        try scheduler.prepareCurrent(position: position)
                        syncSchedulerState()
                    } catch {
                        // A restored file/route can be unavailable at launch. Keep the
                        // queue and position, and allow the next explicit play/load to retry.
                        preparationFailure = error
                    }
                    acceptedSchedulerGeneration = scheduler.currentGeneration
                } else {
                    trackID = nil
                    queueIndex = nil
                    position = 0
                }
                graph.setMasterVolume(Float(masterVolume))
                try graph.setEQ(enabled: eqEnabled, bands: eqBands)
                recallCorrectionForCurrentRoute()
                // Relaunch restores continuity but never surprises the user with autoplay.
                intent = .paused
                outputFormat = graph.outputDescriptor()
                route = outputFormat?.route
                initialized = true
                let snapshot = try publish(eventCode: "ENGINE_INITIALIZED")
                if let preparationFailure { fail(preparationFailure, completion: completion) }
                else { succeed(snapshot, completion: completion) }
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

    func toggle(completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            if intent == .playing {
                if scheduler.isPlaying { scheduler.pause() }
                syncSchedulerState()
                intent = .paused
                acceptedSchedulerGeneration = scheduler.currentGeneration
                return try publish(eventCode: "PLAYBACK_PAUSED")
            }
            guard trackID != nil else { throw CoordinatorError.noTrackLoaded }
            if !interruptionActive { try scheduler.play() }
            intent = .playing
            acceptedSchedulerGeneration = scheduler.currentGeneration
            return try publish(eventCode: "PLAYBACK_STARTED")
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
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            let shouldWrap = repeatMode == .all && !queue.isEmpty && queueIndex == queue.indices.last
            if shouldWrap {
                let resume = scheduler.isPlaying
                try scheduler.setQueue(queue, index: 0, revision: queueRevision)
                try scheduler.setRepeatMode(repeatMode)
                try scheduler.prepareCurrent(position: 0)
                if resume { try scheduler.play() }
            } else {
                try scheduler.next()
            }
            acceptedSchedulerGeneration = scheduler.currentGeneration
            syncSchedulerState()
            sourceFormat = scheduler.currentSourceFormat
            outputFormat = graph.outputDescriptor()
            route = outputFormat?.route
            return try publish(eventCode: "TRACK_NEXT")
        }
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
            sourceFormat = scheduler.currentSourceFormat
            outputFormat = graph.outputDescriptor()
            route = outputFormat?.route
            return try publish(eventCode: "QUEUE_CHANGED")
        }
    }

    func updateQueue(
        items: [QueueItem],
        index: Int,
        revision: UInt64,
        completion: @escaping PlaybackCommandCompletion
    ) {
        setQueue(items: items, index: index, revision: revision, completion: completion)
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

    func setDSP(_ settings: DSPSettings, completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            guard settings.version == 1, settings.trimDB.isFinite, (-24...0).contains(settings.trimDB),
                  settings.profiles.count <= 32, settings.savedPresets.count <= 32 else {
                throw DSPError.invalid("Use −24…0 dB trim and at most 32 saved profiles/presets.")
            }
            for profile in settings.profiles { try CorrectionImport.validate(profile) }
            for preset in settings.savedPresets { try ParametricDSP.validate(preset.bands) }
            if settings.correctionEnabled && settings.correction == nil { throw DSPError.invalid("Select a correction profile first.") }
            try graph.setDSP(settings)
            dsp = settings
            outputFormat = graph.outputDescriptor()
            return try publish(eventCode: "DSP_CHANGED")
        }
    }

    func setEQ(enabled: Bool, bands: [EQBand], completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            if eqEnabled == enabled, eqBands == bands { return currentSnapshot() }
            try graph.setEQ(enabled: enabled, bands: bands)
            eqEnabled = enabled
            eqBands = bands
            outputFormat = graph.outputDescriptor()
            return try publish(eventCode: "EQ_CHANGED")
        }
    }

    func setEQEnabled(_ enabled: Bool, completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            if eqEnabled == enabled { return currentSnapshot() }
            try graph.setEQ(enabled: enabled, bands: eqBands)
            eqEnabled = enabled
            outputFormat = graph.outputDescriptor()
            return try publish(eventCode: "EQ_CHANGED")
        }
    }

    func setEQBands(_ bands: [EQBand], completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            if eqBands == bands { return currentSnapshot() }
            try graph.setEQ(enabled: eqEnabled, bands: bands)
            eqBands = bands
            outputFormat = graph.outputDescriptor()
            return try publish(eventCode: "EQ_CHANGED")
        }
    }

    func setRepeatMode(_ mode: RepeatMode, completion: @escaping PlaybackCommandCompletion) {
        command(completion: completion) { [self] in
            guard initialized else { throw CoordinatorError.notInitialized }
            if repeatMode == mode { return currentSnapshot() }
            try scheduler.setRepeatMode(mode)
            repeatMode = mode
            acceptedSchedulerGeneration = scheduler.currentGeneration
            syncSchedulerState()
            return try publish(eventCode: "REPEAT_CHANGED")
        }
    }

    func getState(completion: @escaping (PlaybackSnapshot) -> Void) {
        transportQueue.async { [weak self] in
            guard let self else { return }
            syncSchedulerState()
            let liveOutput = graph.outputDescriptor()
            let snapshot: PlaybackSnapshot
            if liveOutput != outputFormat {
                outputFormat = liveOutput
                route = liveOutput.route
                snapshot = (try? publish(eventCode: "OUTPUT_REFRESHED")) ?? currentSnapshot()
            } else {
                snapshot = currentSnapshot()
            }
            callbackQueue.async { completion(snapshot) }
        }
    }

    func getDiagnostics(completion: @escaping ([DiagnosticEntry]) -> Void) {
        transportQueue.async { [weak self] in
            guard let self else { return }
            let entries = diagnostics.entries()
            callbackQueue.async { completion(entries) }
        }
    }

    func beginInterruption() {
        transportQueue.async { [weak self] in
            guard let self, initialized, !interruptionActive else { return }
            interruptionActive = true
            if scheduler.isPlaying { scheduler.pause() }
            syncSchedulerState()
            acceptedSchedulerGeneration = scheduler.currentGeneration
            _ = try? publish(eventCode: "INTERRUPTION_BEGIN", additionalEvents: [.interruptionChanged])
        }
    }

    func endInterruption(systemAllowsResume: Bool) {
        transportQueue.async { [weak self] in
            guard let self, initialized, interruptionActive else { return }
            interruptionActive = false
            do {
                if interruptionShouldResume(systemAllowsResume: systemAllowsResume, userIntent: intent) {
                    try scheduler.play()
                }
                acceptedSchedulerGeneration = scheduler.currentGeneration
                syncSchedulerState()
                _ = try publish(eventCode: "INTERRUPTION_END", additionalEvents: [.interruptionChanged])
            } catch {
                fail(error, completion: nil)
            }
        }
    }

    private func recallCorrectionForCurrentRoute() {
        let currentRoute = graph.outputDescriptor().route
        dsp.correctionEnabled = false
        if [.bluetooth, .airPlay].contains(currentRoute.kind), let id = currentRoute.persistentID,
           !id.isEmpty, let profile = dsp.routeBindings[id], dsp.profiles.contains(where: { $0.id == profile }) {
            dsp.correctionID = profile; dsp.correctionEnabled = true
        }
        try? graph.setDSP(dsp)
    }

    func handleAudioSessionEvent(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            beginInterruption()
        case .interruptionEnded(let systemAllowsResume):
            endInterruption(systemAllowsResume: systemAllowsResume)
        case .routeChanged(_, _, let action):
            transportQueue.async { [weak self] in
                guard let self, initialized else { return }
                recallCorrectionForCurrentRoute()
                if action == .pauseAndRebuild {
                    if scheduler.isPlaying { scheduler.pause() }
                    syncSchedulerState()
                    intent = .paused
                    recover(from: .engine, eventCode: "ROUTE_LOSS_RECOVERY")
                } else {
                    outputFormat = graph.outputDescriptor()
                    route = outputFormat?.route
                    _ = try? publish(eventCode: "ROUTE_CHANGED")
                }
            }
        case .mediaServicesLost:
            transportQueue.async { [weak self] in
                guard let self, initialized else { return }
                if scheduler.isPlaying { scheduler.pause() }
                syncSchedulerState()
                acceptedSchedulerGeneration = scheduler.currentGeneration
                _ = try? publish(eventCode: "MEDIA_SERVICES_LOST")
            }
        case .mediaServicesReset:
            transportQueue.async { [weak self] in
                self?.recover(from: .session, eventCode: "MEDIA_SERVICES_RESET")
            }
        case .secondaryAudioSilenced(let silenced):
            transportQueue.async { [weak self] in
                guard let self else { return }
                try? diagnostics.record(
                    eventCode: silenced ? "SECONDARY_AUDIO_SILENCE_BEGIN" : "SECONDARY_AUDIO_SILENCE_END",
                    trackID: trackID,
                    recoverable: true
                )
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
            self.sourceFormat = scheduler.currentSourceFormat ?? sourceFormat
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
            sourceFormat = scheduler.currentSourceFormat
            outputFormat = graph.outputDescriptor()
            route = outputFormat?.route
            return try publish(eventCode: eventCode)
        }
    }

    private func command(completion: @escaping PlaybackCommandCompletion, body: @escaping () throws -> PlaybackSnapshot) {
        transportQueue.async { [weak self] in
            guard let self else { return }
            captureListening()
            do { succeed(try body(), completion: completion) }
            catch { fail(error, completion: completion) }
        }
    }

    private func receive(_ event: SchedulerEvent) {
        transportQueue.async { [weak self] in
            guard let self else { return }
            let token: ScheduleToken
            switch event {
            case .started(_, _, let value), .handoff(_, _, _, let value), .completed(_, let value), .failed(_, _, let value), .skipped(_, let value):
                token = value
            }
            guard token.generation == acceptedSchedulerGeneration else { return }

            switch event {
            case .skipped(let skippedID, _):
                try? diagnostics.record(eventCode: "QUEUE_ITEM_SKIPPED", trackID: skippedID, recoverable: true)
                _ = try? publish(eventCode: "QUEUE_CONTINUED", additionalEvents: [.queueItemSkipped])
            case .started:
                return
            case .handoff(let fromID, _, _, _):
                if listeningRecorder?.trackID == fromID { try? listeningRecorder?.finish(completed: true) }
                syncSchedulerState()
                sourceFormat = scheduler.currentSourceFormat
                outputFormat = graph.outputDescriptor()
                route = outputFormat?.route
                _ = try? publish(eventCode: "TRACK_HANDOFF")
            case .completed(let completedID, _):
                if listeningRecorder?.trackID == completedID { try? listeningRecorder?.finish(completed: true) }
                syncSchedulerState()
                do {
                    if repeatMode == .one {
                        try scheduler.seek(seconds: 0)
                        try scheduler.play()
                        acceptedSchedulerGeneration = scheduler.currentGeneration
                        syncSchedulerState()
                        intent = .playing
                        _ = try publish(eventCode: "TRACK_REPEATED")
                    } else if repeatMode == .all, !queue.isEmpty {
                        try scheduler.setQueue(queue, index: 0, revision: queueRevision)
                        try scheduler.setRepeatMode(repeatMode)
                        try scheduler.prepareCurrent(position: 0)
                        try scheduler.play()
                        acceptedSchedulerGeneration = scheduler.currentGeneration
                        syncSchedulerState()
                        sourceFormat = scheduler.currentSourceFormat
                        intent = .playing
                        _ = try publish(eventCode: "QUEUE_REPEATED")
                    } else {
                        intent = .paused
                        _ = try publish(eventCode: "PLAYBACK_COMPLETED")
                    }
                } catch {
                    intent = .paused
                    _ = try? publish(eventCode: "PLAYBACK_STOPPED")
                    fail(error, completion: nil)
                }
            case .failed(let failedTrackID, let error, _):
                syncSchedulerState()
                if recovery != nil {
                    recover(from: .node, eventCode: "SCHEDULER_RECOVERY", failedTrackID: failedTrackID)
                } else {
                    intent = .paused
                    _ = try? publish(eventCode: "PLAYBACK_STOPPED")
                    fail(error, trackID: failedTrackID, completion: nil)
                }
            }
        }
    }

    private func recover(from level: RecoveryLevel, eventCode: String, failedTrackID: String? = nil) {
        guard initialized, trackID != nil, let recovery else { return }
        let checkpoint = PlaybackRecoveryCheckpoint(position: position, userIntent: intent)
        do {
            let result = try recovery.recover(from: level, checkpoint: checkpoint)
            acceptedSchedulerGeneration = scheduler.currentGeneration
            syncSchedulerState()
            outputFormat = graph.outputDescriptor()
            route = outputFormat?.route
            _ = try publish(
                eventCode: "\(eventCode)_LEVEL_\(result.level.rawValue)",
                additionalEvents: [.engineRecovered]
            )
        } catch {
            scheduler.invalidatePendingSchedule()
            syncSchedulerState()
            intent = .paused
            _ = try? publish(eventCode: "PLAYBACK_STOPPED")
            fail(
                PlaybackFailure(
                    code: "recovery_exhausted",
                    message: "Playback stopped after all recovery levels were exhausted",
                    recoverable: true,
                    trackID: failedTrackID ?? trackID
                ),
                completion: nil
            )
        }
    }

    private func syncSchedulerState() {
        queue = scheduler.queueItems
        queueIndex = scheduler.currentIndex
        queueRevision = scheduler.queueRevision
        trackID = scheduler.currentTrackID
        position = scheduler.currentPosition
        if let schedulerFormat = scheduler.currentSourceFormat {
            sourceFormat = schedulerFormat
        } else if trackID == nil {
            sourceFormat = nil
        }
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
            repeatMode: repeatMode,
            dsp: dsp,
            route: route,
            sourceFormat: sourceFormat,
            outputFormat: outputFormat,
            timestamp: now()
        )
    }

    private func publish(
        eventCode: String,
        additionalEvents: [PlaybackCoordinatorEvent] = []
    ) throws -> PlaybackSnapshot {
        if eventCode == "SOURCE_OPENED" { try? listeningRecorder?.finish(completed: false) }
        captureListening()
        listeningTimer?.schedule(deadline: intent == .playing && scheduler.isPlaying ? .now() + 5 : .distantFuture, repeating: 5)
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
        var events: [PlaybackCoordinatorEvent] = [.stateChanged]
        if let previous = lastPublishedSnapshot {
            if previous.position != snapshot.position { events.append(.positionChanged) }
            if previous.trackID != snapshot.trackID || previous.queueIndex != snapshot.queueIndex {
                events.append(.trackChanged)
            }
            if previous.queueRevision != snapshot.queueRevision || previous.queue != snapshot.queue {
                events.append(.queueChanged)
            }
            if previous.route != snapshot.route { events.append(.routeChanged) }
            if previous.sourceFormat != snapshot.sourceFormat || previous.outputFormat != snapshot.outputFormat {
                events.append(.formatChanged)
            }
        } else {
            events.append(contentsOf: [.positionChanged, .trackChanged, .queueChanged, .routeChanged, .formatChanged])
        }
        for event in additionalEvents where !events.contains(event) { events.append(event) }
        lastPublishedSnapshot = snapshot
        callbackQueue.async { [weak self] in
            guard let self else { return }
            delegate?.playbackCoordinator(self, didPublish: snapshot, events: events)
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
        let detail: String?
        if let schedulerError = error as? QueueSchedulerError,
           case .operation(_, let reason) = schedulerError { detail = reason }
        else { detail = nil }
        try? diagnostics.record(eventCode: "PLAYBACK_ERROR", trackID: failure.trackID,
            sourceFormat: sourceFormat, outputFormat: graph.outputDescriptor(), route: route,
            recoverable: failure.recoverable, failureCode: failure.code, failureDetail: detail)
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
        scheduler.setReplayGain(mode: replayGainMode, preampDB: replayGainPreampDB)
        outputFormat = graph.outputDescriptor()
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
        if let error = error as? DSPError {
            return PlaybackFailure(code: "dsp_parameters", message: error.localizedDescription, recoverable: true, trackID: trackID)
        }
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
            case .operation(let id, let reason):
                if reason.hasPrefix("engine_start:") {
                    return PlaybackFailure(code: "engine_start_failed", message: "Audio output could not start (\(reason)).", recoverable: true, trackID: id ?? trackID)
                }
                let stage = reason.split(separator: ":").first.map(String.init) ?? ""
                let labels: [String: (code: String, message: String)] = [
                    "file_access": ("media_access_failed", "The imported file could not be accessed"),
                    "graph_setup": ("audio_setup_failed", "The audio processing chain could not be prepared"),
                    "decoder_open": ("decoder_open_failed", "The audio file could not be opened for decoding"),
                    "scheduling": ("audio_schedule_failed", "The decoded audio could not be scheduled"),
                    "playback_operation": ("audio_operation_failed", "The audio operation failed")
                ]
                if let label = labels[stage], DiagnosticsLog.safeFailureDetail(reason) != nil {
                    return PlaybackFailure(code: label.code, message: "\(label.message) (\(reason)).",
                        recoverable: true, trackID: id ?? trackID)
                }
                return PlaybackFailure(code: "media_open_failed", message: "Could not prepare media. Open Settings → Diagnostics for the failure code.", recoverable: true, trackID: id ?? trackID)
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

/// Counts time actually spent listening, never seek distance or UI polling events.
/// A play qualifies at 30 seconds or half a shorter track. Pause/resume keeps the
/// occurrence; a handoff (including Repeat One) starts a new occurrence.
final class PlaybackListeningRecorder {
    private let repository: CatalogRepository
    private let uptime: () -> TimeInterval
    private(set) var trackID: String?
    private var queueIndex: Int?
    private var elapsed: TimeInterval = 0
    private var lastTick: TimeInterval?
    private var wasPlaying = false
    private var counted = false
    private var position = 0.0
    private var threshold = 30.0

    init(repository: CatalogRepository, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.repository = repository
        self.uptime = uptime
    }

    func sample(trackID: String?, queueIndex: Int?, position: Double, duration: Double?, playing: Bool) throws {
        if self.trackID != trackID || self.queueIndex != queueIndex {
            try finish(completed: false)
            self.trackID = trackID
            self.queueIndex = queueIndex
        }
        accrue()
        self.position = position.isFinite ? max(0, position) : 0
        threshold = duration.flatMap { $0.isFinite && $0 > 0 ? min(30, $0 / 2) : nil } ?? 30
        let stopped = wasPlaying && !playing
        wasPlaying = playing
        try qualify(completed: false)
        if stopped, counted, let trackID {
            try repository.updateListeningProgress(trackID: trackID, position: self.position, completed: false)
        }
    }

    func finish(completed: Bool) throws {
        accrue()
        defer {
            trackID = nil; queueIndex = nil; elapsed = 0; lastTick = nil
            wasPlaying = false; counted = false; position = 0; threshold = 30
        }
        let previouslyCounted = counted
        try qualify(completed: completed)
        if previouslyCounted, let trackID {
            try repository.updateListeningProgress(trackID: trackID, position: position, completed: completed)
        }
    }

    private func accrue() {
        let tick = uptime()
        if wasPlaying, let lastTick { elapsed += max(0, tick - lastTick) }
        lastTick = tick
    }

    private func qualify(completed: Bool) throws {
        guard !counted, elapsed >= threshold, let trackID else { return }
        try repository.recordPlay(trackID: trackID, completed: completed, lastPosition: position)
        counted = true
    }
}
