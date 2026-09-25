import Combine
import Foundation

protocol PlaybackCoordinating: AnyObject {
    var delegate: PlaybackCoordinatorDelegate? { get set }

    func initialize(completion: @escaping PlaybackCommandCompletion)
    func load(
        trackID: String,
        mediaRef: MediaReference,
        queue: [QueueItem]?,
        index: Int?,
        completion: @escaping PlaybackCommandCompletion
    )
    func play(completion: @escaping PlaybackCommandCompletion)
    func pause(completion: @escaping PlaybackCommandCompletion)
    func toggle(completion: @escaping PlaybackCommandCompletion)
    func seek(seconds: Double, completion: @escaping PlaybackCommandCompletion)
    func next(completion: @escaping PlaybackCommandCompletion)
    func previous(completion: @escaping PlaybackCommandCompletion)
    func setQueue(items: [QueueItem], index: Int, revision: UInt64, completion: @escaping PlaybackCommandCompletion)
    func setVolume(_ value: Float, completion: @escaping PlaybackCommandCompletion)
    func setReplayGainMode(_ mode: ReplayGainMode, completion: @escaping PlaybackCommandCompletion)
    func setReplayGainPreamp(_ db: Double, completion: @escaping PlaybackCommandCompletion)
    func setDSP(_ settings: DSPSettings, completion: @escaping PlaybackCommandCompletion)
    func setEQ(enabled: Bool, bands: [EQBand], completion: @escaping PlaybackCommandCompletion)
    func setRepeatMode(_ mode: RepeatMode, completion: @escaping PlaybackCommandCompletion)
    func getState(completion: @escaping (PlaybackSnapshot) -> Void)
}

extension PlaybackCoordinator: PlaybackCoordinating {}
extension PlaybackCoordinating {
    func setDSP(_ settings: DSPSettings, completion: @escaping PlaybackCommandCompletion) {
        completion(.failure(PlaybackFailure(code: "DSP_UNAVAILABLE", message: "DSP is unavailable in this fixture.", recoverable: true, trackID: nil)))
    }
}

protocol QueuePlaylistPersisting: AnyObject {
    @discardableResult
    func createPlaylist(name: String, trackIDs: [String], id: String, at date: Date) throws -> CatalogPlaylist
}

extension CatalogRepository: QueuePlaylistPersisting {}

enum SpectrumMode: String, CaseIterable, Identifiable {
    case off
    case ambient
    case full

    var id: String { rawValue }
}

@MainActor
final class PlaybackController: ObservableObject, PlaybackCoordinatorDelegate {
    @Published private(set) var snapshot: PlaybackSnapshot?
    @Published private(set) var failure: PlaybackFailure?
    @Published private(set) var isInitialized = false
    @Published private(set) var queueMessage: String?
    @Published private(set) var spectrumMode: SpectrumMode = .ambient

    private let coordinator: PlaybackCoordinating
    private weak var playlistStore: QueuePlaylistPersisting?
    private var latestVersion: UInt64 = 0
    private var positionTimer: Timer?

    init(
        coordinator: PlaybackCoordinating,
        playlistStore: QueuePlaylistPersisting? = nil
    ) {
        self.coordinator = coordinator
        self.playlistStore = playlistStore
        coordinator.delegate = self
    }

    deinit { positionTimer?.invalidate() }

    func stopRefreshing() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    func start() {
        coordinator.initialize { [weak self] result in self?.accept(result) }
    }

    func applicationDidEnterForeground() {
        coordinator.getState { [weak self] snapshot in self?.accept(snapshot: snapshot) }
    }

    func applicationDidEnterBackground() { stopPositionRefresh() }

    func load(track: CatalogTrack, queue: [QueueItem]? = nil, index: Int? = nil) {
        coordinator.load(
            trackID: track.id,
            mediaRef: track.mediaReference,
            queue: queue,
            index: index
        ) { [weak self] result in self?.accept(result) }
    }

    /// User-initiated track selection is one ordered transport operation. Native load performs
    /// asynchronous media inspection, so issuing play() immediately after load() races the load
    /// and can fail with track_not_loaded before the source is prepared.
    func loadAndPlay(track: CatalogTrack, queue: [QueueItem]? = nil, index: Int? = nil) {
        coordinator.load(
            trackID: track.id,
            mediaRef: track.mediaReference,
            queue: queue,
            index: index
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.accept(result)
            case .success(let loaded):
                self.accept(snapshot: loaded)
                self.coordinator.play { [weak self] playResult in self?.accept(playResult, clearsFailure: true) }
            }
        }
    }

    func play() { coordinator.play { [weak self] result in self?.accept(result, clearsFailure: true) } }
    func pause() { coordinator.pause { [weak self] result in self?.accept(result) } }
    func toggle() { coordinator.toggle { [weak self] result in self?.accept(result, clearsFailure: true) } }
    func seek(to seconds: Double, completion: (() -> Void)? = nil) {
        coordinator.seek(seconds: seconds) { [weak self] result in
            self?.accept(result, clearsFailure: true)
            completion?()
        }
    }
    func next() { coordinator.next { [weak self] result in self?.accept(result) } }
    func previous() { coordinator.previous { [weak self] result in self?.accept(result) } }
    func setQueue(_ items: [QueueItem], index: Int, revision: UInt64) {
        coordinator.setQueue(items: items, index: index, revision: revision) { [weak self] result in self?.accept(result) }
    }
    func setVolume(_ value: Float) { coordinator.setVolume(value) { [weak self] result in self?.accept(result) } }
    func setReplayGainMode(_ mode: ReplayGainMode) {
        coordinator.setReplayGainMode(mode) { [weak self] result in self?.accept(result) }
    }
    func setReplayGainPreamp(_ db: Double) {
        coordinator.setReplayGainPreamp(db) { [weak self] result in self?.accept(result) }
    }
    func setDSP(_ settings: DSPSettings) {
        coordinator.setDSP(settings) { [weak self] result in self?.accept(result) }
    }

    func setEQ(enabled: Bool, bands: [EQBand]) {
        coordinator.setEQ(enabled: enabled, bands: bands) { [weak self] result in self?.accept(result) }
    }
    func setRepeatMode(_ mode: RepeatMode) {
        coordinator.setRepeatMode(mode) { [weak self] result in self?.accept(result) }
    }

    func cycleRepeatMode() {
        let current = snapshot?.repeatMode ?? .off
        let modes = RepeatMode.allCases
        let next = modes[(modes.firstIndex(of: current)! + 1) % modes.count]
        setRepeatMode(next)
    }

    func setSpectrumMode(_ mode: SpectrumMode) { spectrumMode = mode }

    func moveUpcoming(fromOffsets: IndexSet, toOffset: Int) {
        guard let snapshot, let currentIndex = snapshot.queueIndex,
              snapshot.queue.indices.contains(currentIndex), !fromOffsets.isEmpty else { return }
        var upcoming = Array(snapshot.queue.suffix(from: currentIndex + 1))
        let validOffsets = fromOffsets.sorted().filter { upcoming.indices.contains($0) }
        guard validOffsets.count == fromOffsets.count else { return }
        let moved = validOffsets.map { upcoming[$0] }
        for index in validOffsets.reversed() { upcoming.remove(at: index) }
        let removedBeforeDestination = validOffsets.filter { $0 < toOffset }.count
        let insertion = min(upcoming.count, max(0, toOffset - removedBeforeDestination))
        upcoming.insert(contentsOf: moved, at: insertion)
        let revised = Array(snapshot.queue.prefix(currentIndex + 1)) + upcoming
        commitQueue(revised, currentIndex: currentIndex, message: nil)
    }

    func clearUpcoming() {
        guard let snapshot, let currentIndex = snapshot.queueIndex,
              snapshot.queue.indices.contains(currentIndex), currentIndex < snapshot.queue.count - 1 else { return }
        commitQueue(
            Array(snapshot.queue.prefix(currentIndex + 1)),
            currentIndex: currentIndex,
            message: "Upcoming tracks cleared. Current track keeps playing."
        )
    }

    func playNext(_ track: CatalogTrack) {
        let item = QueueItem(trackID: track.id, albumID: track.albumID, mediaRef: track.mediaReference)
        guard let snapshot, let currentIndex = snapshot.queueIndex,
              snapshot.queue.indices.contains(currentIndex) else {
            loadAndPlay(track: track, queue: [item], index: 0)
            return
        }
        var revised = snapshot.queue
        revised.insert(item, at: currentIndex + 1)
        commitQueue(revised, currentIndex: currentIndex, message: "Playing next: \(track.title).")
    }

    func addToQueue(_ track: CatalogTrack) {
        let item = QueueItem(trackID: track.id, albumID: track.albumID, mediaRef: track.mediaReference)
        guard let snapshot, let currentIndex = snapshot.queueIndex,
              snapshot.queue.indices.contains(currentIndex) else {
            loadAndPlay(track: track, queue: [item], index: 0)
            return
        }
        commitQueue(snapshot.queue + [item], currentIndex: currentIndex, message: "Added to queue: \(track.title).")
    }

    func removeFromQueue(at index: Int) {
        guard let snapshot, let currentIndex = snapshot.queueIndex,
              snapshot.queue.indices.contains(index), index != currentIndex else { return }
        var revised = snapshot.queue
        revised.remove(at: index)
        let revisedCurrent = index < currentIndex ? currentIndex - 1 : currentIndex
        commitQueue(revised, currentIndex: revisedCurrent, message: "Removed from queue.")
    }

    func shuffleUpcoming() {
        var generator = SystemRandomNumberGenerator()
        shuffleUpcoming(using: &generator)
    }

    func shuffleUpcoming<R: RandomNumberGenerator>(using generator: inout R) {
        guard let snapshot, let currentIndex = snapshot.queueIndex,
              snapshot.queue.indices.contains(currentIndex) else { return }
        var upcoming = Array(snapshot.queue.suffix(from: currentIndex + 1))
        guard upcoming.count > 1 else {
            queueMessage = "Not enough upcoming tracks to shuffle."
            return
        }
        let original = upcoming
        upcoming.shuffle(using: &generator)
        if upcoming == original { upcoming.swapAt(0, 1) }
        commitQueue(
            Array(snapshot.queue.prefix(currentIndex + 1)) + upcoming,
            currentIndex: currentIndex,
            message: "Upcoming queue shuffled."
        )
    }

    @discardableResult
    func saveQueueAsPlaylist(name: String, id: String = UUID().uuidString, at date: Date = Date()) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            queueMessage = "Name this queue before saving."
            return false
        }
        guard let trackIDs = snapshot?.queue.map(\.trackID), !trackIDs.isEmpty, let playlistStore else {
            queueMessage = "There is no queue to save."
            return false
        }
        do {
            _ = try playlistStore.createPlaylist(name: trimmed, trackIDs: trackIDs, id: id, at: date)
            queueMessage = "Saved \u{201c}\(trimmed)\u{201d} with \(trackIDs.count) tracks."
            return true
        } catch {
            queueMessage = "The playlist could not be saved. The queue was not changed."
            return false
        }
    }

    func clearQueueMessage() { queueMessage = nil }

    func dismissFailure() { failure = nil }

    nonisolated func playbackCoordinator(
        _ coordinator: PlaybackCoordinator,
        didPublish snapshot: PlaybackSnapshot,
        events: [PlaybackCoordinatorEvent]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if events.contains(.engineRecovered), snapshot.version >= latestVersion,
               snapshot.intent == .playing, failure?.recoverable == true { failure = nil }
            accept(snapshot: snapshot)
            if events.contains(.queueItemSkipped), snapshot.version >= latestVersion {
                queueMessage = "An unavailable upcoming track was skipped. Your current track continues."
            }
        }
    }

    nonisolated func playbackCoordinator(
        _ coordinator: PlaybackCoordinator,
        didFail failure: PlaybackFailure,
        version: UInt64
    ) {
        Task { @MainActor [weak self] in self?.accept(failure: failure, version: version) }
    }

    func accept(snapshot: PlaybackSnapshot) {
        guard snapshot.version >= latestVersion else { return }
        latestVersion = snapshot.version
        self.snapshot = snapshot
        isInitialized = true
        if failure?.trackID != nil, failure?.trackID != snapshot.trackID { failure = nil }
        updatePositionRefresh(for: snapshot.intent)
    }

    func accept(failure: PlaybackFailure, version: UInt64) {
        guard version >= latestVersion, failure.code != "stale_operation" else { return }
        self.failure = failure
    }

    private func accept(_ result: Result<PlaybackSnapshot, PlaybackFailure>, clearsFailure: Bool = false) {
        switch result {
        case .success(let snapshot):
            if clearsFailure, snapshot.version >= latestVersion, failure?.recoverable == true { failure = nil }
            accept(snapshot: snapshot)
        case .failure(let failure): accept(failure: failure, version: latestVersion)
        }
    }

    private func commitQueue(_ items: [QueueItem], currentIndex: Int, message: String?) {
        guard let snapshot, snapshot.queueRevision < .max, items != snapshot.queue else { return }
        queueMessage = message
        setQueue(items, index: currentIndex, revision: snapshot.queueRevision + 1)
    }

    private func updatePositionRefresh(for intent: PlaybackIntent) {
        guard intent == .playing else {
            stopPositionRefresh()
            return
        }
        guard positionTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func stopPositionRefresh() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func refreshPosition() {
        coordinator.getState { [weak self] snapshot in self?.accept(snapshot: snapshot) }
    }
}

/// Deterministic playback authority used by simulator fixtures. It preserves the
/// same command/state contract as the native coordinator without opening CoreAudio.
#if DEBUG
final class PlaybackFixtureCoordinator: PlaybackCoordinating {
    weak var delegate: PlaybackCoordinatorDelegate?
    private var state: FixtureState

    init(snapshot: PlaybackSnapshot?) {
        state = FixtureState(snapshot: snapshot ?? FixtureState.emptySnapshot())
    }

    func initialize(completion: @escaping PlaybackCommandCompletion) {
        completion(.success(state.snapshot()))
    }

    func load(
        trackID: String,
        mediaRef: MediaReference,
        queue requestedQueue: [QueueItem]?,
        index requestedIndex: Int?,
        completion: @escaping PlaybackCommandCompletion
    ) {
        guard !trackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(failure(code: "invalid_track", message: "Track identifier is required", trackID: trackID)))
            return
        }
        let items = requestedQueue ?? [QueueItem(trackID: trackID, albumID: "fixture", mediaRef: mediaRef)]
        let index = requestedIndex ?? (items.firstIndex { $0.trackID == trackID } ?? 0)
        guard items.indices.contains(index) else {
            completion(.failure(failure(code: "invalid_queue", message: "Queue index is invalid", trackID: trackID)))
            return
        }
        state.queue = items
        state.queueIndex = index
        state.trackID = items[index].trackID
        state.position = 0
        state.intent = .paused
        publish(completion)
    }

    func play(completion: @escaping PlaybackCommandCompletion) {
        guard state.trackID != nil else {
            completion(.failure(failure(code: "no_track", message: "No track is loaded", trackID: nil)))
            return
        }
        state.intent = .playing
        publish(completion)
    }

    func pause(completion: @escaping PlaybackCommandCompletion) {
        state.intent = .paused
        publish(completion)
    }

    func toggle(completion: @escaping PlaybackCommandCompletion) {
        state.intent = state.intent == .playing ? .paused : .playing
        publish(completion)
    }

    func seek(seconds: Double, completion: @escaping PlaybackCommandCompletion) {
        guard seconds.isFinite, seconds >= 0 else {
            completion(.failure(failure(code: "invalid_position", message: "Playback position is invalid", trackID: state.trackID)))
            return
        }
        state.position = seconds
        publish(completion)
    }

    func next(completion: @escaping PlaybackCommandCompletion) {
        guard let index = state.queueIndex, !state.queue.isEmpty else {
            completion(.failure(failure(code: "no_track", message: "No track is loaded", trackID: nil)))
            return
        }
        let nextIndex = min(index + 1, state.queue.count - 1)
        state.queueIndex = nextIndex
        state.trackID = state.queue[nextIndex].trackID
        state.position = 0
        publish(completion)
    }

    func previous(completion: @escaping PlaybackCommandCompletion) {
        guard let index = state.queueIndex, !state.queue.isEmpty else {
            completion(.failure(failure(code: "no_track", message: "No track is loaded", trackID: nil)))
            return
        }
        let previousIndex = max(index - 1, 0)
        state.queueIndex = previousIndex
        state.trackID = state.queue[previousIndex].trackID
        state.position = 0
        publish(completion)
    }

    func setQueue(
        items: [QueueItem],
        index: Int,
        revision: UInt64,
        completion: @escaping PlaybackCommandCompletion
    ) {
        guard revision > state.queueRevision else {
            completion(.failure(failure(code: "stale_queue", message: "Queue revision is stale", trackID: state.trackID)))
            return
        }
        guard items.indices.contains(index) || (items.isEmpty && index == 0) else {
            completion(.failure(failure(code: "invalid_queue", message: "Queue index is invalid", trackID: state.trackID)))
            return
        }
        state.queue = items
        state.queueRevision = revision
        state.queueIndex = items.isEmpty ? nil : index
        state.trackID = items.isEmpty ? nil : items[index].trackID
        state.position = items.isEmpty ? 0 : state.position
        publish(completion)
    }

    func setVolume(_ value: Float, completion: @escaping PlaybackCommandCompletion) {
        guard value.isFinite, (0...1).contains(value) else {
            completion(.failure(failure(code: "invalid_volume", message: "Volume is invalid", trackID: state.trackID)))
            return
        }
        state.masterVolume = Double(value)
        publish(completion)
    }

    func setReplayGainMode(_ mode: ReplayGainMode, completion: @escaping PlaybackCommandCompletion) {
        state.replayGainMode = mode
        publish(completion)
    }

    func setReplayGainPreamp(_ db: Double, completion: @escaping PlaybackCommandCompletion) {
        guard db.isFinite else {
            completion(.failure(failure(code: "invalid_replay_gain", message: "ReplayGain preamp is invalid", trackID: state.trackID)))
            return
        }
        state.replayGainPreampDB = db
        publish(completion)
    }

    func setDSP(_ settings: DSPSettings, completion: @escaping PlaybackCommandCompletion) {
        state.dsp = settings
        state.version += 1
        completion(.success(state.snapshot()))
    }

    func setEQ(enabled: Bool, bands: [EQBand], completion: @escaping PlaybackCommandCompletion) {
        state.eqEnabled = enabled
        state.eqBands = bands
        publish(completion)
    }

    func setRepeatMode(_ mode: RepeatMode, completion: @escaping PlaybackCommandCompletion) {
        state.repeatMode = mode
        publish(completion)
    }

    func getState(completion: @escaping (PlaybackSnapshot) -> Void) {
        completion(state.snapshot())
    }

    private func publish(_ completion: @escaping PlaybackCommandCompletion) {
        state.version += 1
        completion(.success(state.snapshot()))
    }

    private func failure(code: String, message: String, trackID: String?) -> PlaybackFailure {
        PlaybackFailure(code: code, message: message, recoverable: true, trackID: trackID)
    }
}

private struct FixtureState {
    var schemaVersion: Int
    var version: UInt64
    var trackID: String?
    var queueRevision: UInt64
    var queue: [QueueItem]
    var queueIndex: Int?
    var position: Double
    var intent: PlaybackIntent
    var replayGainMode: ReplayGainMode
    var replayGainPreampDB: Double
    var masterVolume: Double
    var eqEnabled: Bool
    var eqBands: [EQBand]
    var dsp: DSPSettings
    var repeatMode: RepeatMode
    var route: RouteDescriptor?
    var sourceFormat: SourceFormatDescriptor?
    var outputFormat: OutputFormatDescriptor?
    var timestamp: Date

    init(snapshot: PlaybackSnapshot) {
        schemaVersion = snapshot.schemaVersion
        version = snapshot.version
        trackID = snapshot.trackID
        queueRevision = snapshot.queueRevision
        queue = snapshot.queue
        queueIndex = snapshot.queueIndex
        position = snapshot.position
        intent = snapshot.intent
        replayGainMode = snapshot.replayGainMode
        replayGainPreampDB = snapshot.replayGainPreampDB
        masterVolume = snapshot.masterVolume
        eqEnabled = snapshot.eqEnabled
        eqBands = snapshot.eqBands
        dsp = snapshot.dsp
        repeatMode = snapshot.repeatMode
        route = snapshot.route
        sourceFormat = snapshot.sourceFormat
        outputFormat = snapshot.outputFormat
        timestamp = snapshot.timestamp
    }

    func snapshot() -> PlaybackSnapshot {
        PlaybackSnapshot(
            schemaVersion: schemaVersion,
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
            timestamp: timestamp
        )
    }

    static func emptySnapshot() -> PlaybackSnapshot {
        PlaybackSnapshot(
            version: 0,
            trackID: nil,
            queueRevision: 0,
            queue: [],
            queueIndex: nil,
            position: 0,
            intent: .paused,
            replayGainMode: .off,
            replayGainPreampDB: 0,
            masterVolume: 1,
            eqEnabled: false,
            eqBands: [],
            route: nil,
            sourceFormat: nil,
            outputFormat: nil,
            timestamp: Date()
        )
    }
}

#endif
