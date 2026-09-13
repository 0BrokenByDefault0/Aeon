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
    func setEQ(enabled: Bool, bands: [EQBand], completion: @escaping PlaybackCommandCompletion)
    func getState(completion: @escaping (PlaybackSnapshot) -> Void)
}

extension PlaybackCoordinator: PlaybackCoordinating {}

@MainActor
final class PlaybackController: ObservableObject, PlaybackCoordinatorDelegate {
    @Published private(set) var snapshot: PlaybackSnapshot?
    @Published private(set) var failure: PlaybackFailure?
    @Published private(set) var isInitialized = false

    private let coordinator: PlaybackCoordinating
    private var latestVersion: UInt64 = 0

    init(coordinator: PlaybackCoordinating) {
        self.coordinator = coordinator
        coordinator.delegate = self
    }

    func start() {
        coordinator.initialize { [weak self] result in self?.accept(result) }
    }

    func applicationDidEnterForeground() {
        coordinator.getState { [weak self] snapshot in self?.accept(snapshot: snapshot) }
    }

    func load(track: CatalogTrack, queue: [QueueItem]? = nil, index: Int? = nil) {
        coordinator.load(
            trackID: track.id,
            mediaRef: track.mediaReference,
            queue: queue,
            index: index
        ) { [weak self] result in self?.accept(result) }
    }

    func play() { coordinator.play { [weak self] result in self?.accept(result) } }
    func pause() { coordinator.pause { [weak self] result in self?.accept(result) } }
    func toggle() { coordinator.toggle { [weak self] result in self?.accept(result) } }
    func seek(to seconds: Double) { coordinator.seek(seconds: seconds) { [weak self] result in self?.accept(result) } }
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
    func setEQ(enabled: Bool, bands: [EQBand]) {
        coordinator.setEQ(enabled: enabled, bands: bands) { [weak self] result in self?.accept(result) }
    }

    func dismissFailure() { failure = nil }

    nonisolated func playbackCoordinator(
        _ coordinator: PlaybackCoordinator,
        didPublish snapshot: PlaybackSnapshot,
        events: [PlaybackCoordinatorEvent]
    ) {
        Task { @MainActor [weak self] in self?.accept(snapshot: snapshot) }
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
    }

    func accept(failure: PlaybackFailure, version: UInt64) {
        guard version >= latestVersion, failure.code != "stale_operation" else { return }
        self.failure = failure
    }

    private func accept(_ result: Result<PlaybackSnapshot, PlaybackFailure>) {
        switch result {
        case .success(let snapshot): accept(snapshot: snapshot)
        case .failure(let failure): accept(failure: failure, version: latestVersion)
        }
    }
}
