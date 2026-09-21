import XCTest
@testable import App

@MainActor
final class QueueControllerTests: XCTestCase {
    func testMoveReordersUpcomingOnlyAndSendsOneRevision() {
        let coordinator = QueueRecordingCoordinator(snapshot: makeSnapshot())
        let controller = PlaybackController(coordinator: coordinator)
        controller.accept(snapshot: coordinator.snapshot)

        controller.moveUpcoming(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        XCTAssertEqual(coordinator.queueCalls.count, 1)
        XCTAssertEqual(coordinator.queueCalls[0].items.map(\.trackID), ["past", "current", "last", "next"])
        XCTAssertEqual(coordinator.queueCalls[0].index, 1)
        XCTAssertEqual(coordinator.queueCalls[0].revision, 8)
    }

    func testLastToFirstThenQueueActionsKeepOrderAndNoOpDoesNotCommit() {
        let coordinator = QueueRecordingCoordinator(snapshot: makeSnapshot())
        let controller = PlaybackController(coordinator: coordinator)
        controller.accept(snapshot: coordinator.snapshot)
        controller.moveUpcoming(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(coordinator.queueCalls.last?.items.map(\.trackID), ["past", "current", "last", "next"])
        XCTAssertNil(controller.queueMessage)
        controller.moveUpcoming(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        XCTAssertEqual(coordinator.queueCalls.count, 1)
        controller.addToQueue(track("appended"))
        controller.playNext(track("immediate"))
        XCTAssertEqual(coordinator.queueCalls.last?.items.map(\.trackID), ["past", "current", "immediate", "last", "next", "appended"])
        XCTAssertEqual(coordinator.queueCalls.last?.index, 1)
    }

    func testClearUpcomingPinsHistoryAndCurrent() {
        let coordinator = QueueRecordingCoordinator(snapshot: makeSnapshot())
        let controller = PlaybackController(coordinator: coordinator)
        controller.accept(snapshot: coordinator.snapshot)

        controller.clearUpcoming()

        XCTAssertEqual(coordinator.queueCalls.count, 1)
        XCTAssertEqual(coordinator.queueCalls[0].items.map(\.trackID), ["past", "current"])
        XCTAssertEqual(coordinator.queueCalls[0].index, 1)
    }

    func testPlayNextInsertsImmediatelyAfterCurrentWithoutChangingCurrent() {
        let coordinator = QueueRecordingCoordinator(snapshot: makeSnapshot())
        let controller = PlaybackController(coordinator: coordinator)
        controller.accept(snapshot: coordinator.snapshot)
        controller.playNext(track("urgent"))

        XCTAssertEqual(coordinator.queueCalls[0].items.map(\.trackID), ["past", "current", "urgent", "next", "last"])
        XCTAssertEqual(coordinator.queueCalls[0].index, 1)
    }

    func testAddToQueueAppendsAndRemoveUsesDistinctMutation() {
        let coordinator = QueueRecordingCoordinator(snapshot: makeSnapshot())
        let controller = PlaybackController(coordinator: coordinator)
        controller.accept(snapshot: coordinator.snapshot)
        controller.addToQueue(track("later"))
        XCTAssertEqual(coordinator.queueCalls[0].items.map(\.trackID), ["past", "current", "next", "last", "later"])

        controller.removeFromQueue(at: 2)
        XCTAssertEqual(coordinator.queueCalls[1].items.map(\.trackID), ["past", "current", "last", "later"])
        XCTAssertEqual(coordinator.queueCalls[1].index, 1)
    }

    func testShuffleNeverMovesPastOrCurrentRows() {
        let coordinator = QueueRecordingCoordinator(snapshot: makeSnapshot())
        let controller = PlaybackController(coordinator: coordinator)
        controller.accept(snapshot: coordinator.snapshot)
        var generator = SeededGenerator(seed: 4)

        controller.shuffleUpcoming(using: &generator)

        let ids = coordinator.queueCalls[0].items.map(\.trackID)
        XCTAssertEqual(Array(ids.prefix(2)), ["past", "current"])
        XCTAssertEqual(Set(ids.suffix(2)), Set(["next", "last"]))
        XCTAssertEqual(coordinator.queueCalls.count, 1)
    }

    func testEmptyPlaylistNameIsRejectedWithoutPersistenceOrQueueMutation() {
        let coordinator = QueueRecordingCoordinator(snapshot: makeSnapshot())
        let store = QueuePlaylistStore()
        let controller = PlaybackController(coordinator: coordinator, playlistStore: store)
        controller.accept(snapshot: coordinator.snapshot)

        XCTAssertFalse(controller.saveQueueAsPlaylist(name: "   "))
        XCTAssertTrue(store.calls.isEmpty)
        XCTAssertTrue(coordinator.queueCalls.isEmpty)
    }

    func testPlaylistFailurePreservesQueueState() {
        let original = makeSnapshot()
        let coordinator = QueueRecordingCoordinator(snapshot: original)
        let store = QueuePlaylistStore()
        store.shouldFail = true
        let controller = PlaybackController(coordinator: coordinator, playlistStore: store)
        controller.accept(snapshot: original)

        XCTAssertFalse(controller.saveQueueAsPlaylist(name: "Night route", id: "playlist-1"))

        XCTAssertEqual(controller.snapshot?.queue, original.queue)
        XCTAssertTrue(coordinator.queueCalls.isEmpty)
        XCTAssertEqual(controller.queueMessage, "The playlist could not be saved. The queue was not changed.")
    }

    func testPlaylistSaveUsesCompleteQueueInStableOrder() {
        let coordinator = QueueRecordingCoordinator(snapshot: makeSnapshot())
        let store = QueuePlaylistStore()
        let controller = PlaybackController(coordinator: coordinator, playlistStore: store)
        controller.accept(snapshot: coordinator.snapshot)

        XCTAssertTrue(controller.saveQueueAsPlaylist(name: "  Night route  ", id: "playlist-1"))

        XCTAssertEqual(store.calls.first?.name, "Night route")
        XCTAssertEqual(store.calls.first?.trackIDs, ["past", "current", "next", "last"])
        XCTAssertTrue(coordinator.queueCalls.isEmpty)
    }

    private func makeSnapshot() -> PlaybackSnapshot {
        let items = ["past", "current", "next", "last"].map {
            QueueItem(trackID: $0, albumID: "album", mediaRef: .native(relativePath: "\($0).wav"))
        }
        return PlaybackSnapshot(
            version: 3,
            trackID: "current",
            queueRevision: 7,
            queue: items,
            queueIndex: 1,
            position: 14,
            intent: .paused,
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

    private func track(_ id: String) -> CatalogTrack {
        CatalogTrack(
            id: id, albumID: "album", sequence: 1, discNumber: 1, trackNumber: 1,
            title: id.capitalized, artist: "Artist", duration: 120, byteCount: 32,
            mediaReference: .native(relativePath: "\(id).wav"), importedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private final class QueueRecordingCoordinator: PlaybackCoordinating {
    struct QueueCall {
        let items: [QueueItem]
        let index: Int
        let revision: UInt64
    }

    weak var delegate: PlaybackCoordinatorDelegate?
    var snapshot: PlaybackSnapshot
    private(set) var queueCalls: [QueueCall] = []

    init(snapshot: PlaybackSnapshot) { self.snapshot = snapshot }

    func initialize(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func load(trackID: String, mediaRef: MediaReference, queue: [QueueItem]?, index: Int?, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func play(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func pause(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func toggle(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func seek(seconds: Double, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func next(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func previous(completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func setQueue(items: [QueueItem], index: Int, revision: UInt64, completion: @escaping PlaybackCommandCompletion) {
        queueCalls.append(QueueCall(items: items, index: index, revision: revision))
        snapshot = PlaybackSnapshot(
            version: snapshot.version + 1,
            trackID: items.indices.contains(index) ? items[index].trackID : nil,
            queueRevision: revision,
            queue: items,
            queueIndex: items.isEmpty ? nil : index,
            position: snapshot.position,
            intent: snapshot.intent,
            replayGainMode: snapshot.replayGainMode,
            replayGainPreampDB: snapshot.replayGainPreampDB,
            masterVolume: snapshot.masterVolume,
            eqEnabled: snapshot.eqEnabled,
            eqBands: snapshot.eqBands,
            repeatMode: snapshot.repeatMode,
            route: snapshot.route,
            sourceFormat: snapshot.sourceFormat,
            outputFormat: snapshot.outputFormat,
            timestamp: snapshot.timestamp
        )
        completion(.success(snapshot))
    }
    func setVolume(_ value: Float, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func setReplayGainMode(_ mode: ReplayGainMode, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func setReplayGainPreamp(_ db: Double, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func setEQ(enabled: Bool, bands: [EQBand], completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func setRepeatMode(_ mode: RepeatMode, completion: @escaping PlaybackCommandCompletion) { completion(.success(snapshot)) }
    func getState(completion: @escaping (PlaybackSnapshot) -> Void) { completion(snapshot) }
}

private final class QueuePlaylistStore: QueuePlaylistPersisting {
    enum Failure: Error { case rejected }
    struct Call { let name: String; let trackIDs: [String] }
    var shouldFail = false
    private(set) var calls: [Call] = []

    func createPlaylist(name: String, trackIDs: [String], id: String, at date: Date) throws -> CatalogPlaylist {
        calls.append(Call(name: name, trackIDs: trackIDs))
        if shouldFail { throw Failure.rejected }
        return CatalogPlaylist(id: id, name: name, createdAt: date, updatedAt: date)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return seed
    }
}
