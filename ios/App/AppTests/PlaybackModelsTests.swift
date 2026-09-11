import XCTest
@testable import App

final class PlaybackModelsTests: XCTestCase {
    func testPlaybackSnapshotRoundTripsWithoutLosingVersion() throws {
        let snapshot = makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)

        XCTAssertEqual(try JSONDecoder().decode(PlaybackSnapshot.self, from: data), snapshot)
    }

    func testMediaReferenceUsesStableBridgeSafeJSONShapes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertEqual(String(data: try encoder.encode(MediaReference.native(relativePath: "Music/a.flac")), encoding: .utf8), "{\"relativePath\":\"Music\\/a.flac\",\"type\":\"native\"}")
        XCTAssertEqual(String(data: try encoder.encode(MediaReference.externalBookmark(Data([0, 1, 2]))), encoding: .utf8), "{\"bookmark\":\"AAEC\",\"type\":\"externalBookmark\"}")
        XCTAssertEqual(String(data: try encoder.encode(MediaReference.legacyBlob(trackID: "t1")), encoding: .utf8), "{\"trackID\":\"t1\",\"type\":\"legacyBlob\"}")
    }

    func testMediaReferenceRejectsUnknownDiscriminator() {
        let data = Data(#"{"type":"future","relativePath":"Music/a.flac"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MediaReference.self, from: data))
    }

    func testPlaybackSnapshotJSONContractHasExpectedTopLevelKeys() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(makeSnapshot())) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set([
            "schemaVersion", "version", "trackID", "queueRevision", "queue", "queueIndex",
            "position", "intent", "replayGainMode", "replayGainPreampDB", "masterVolume",
            "eqEnabled", "eqBands", "route", "sourceFormat", "outputFormat", "timestamp"
        ]))
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }

    func testStateVersionClockOnlyMovesForward() {
        let clock = StateVersionClock(seed: 8)
        XCTAssertEqual(clock.next(), 9)
        XCTAssertEqual(clock.next(), 10)
    }

    func testStateVersionClockIsThreadSafe() {
        let clock = StateVersionClock(seed: 0)
        let queue = DispatchQueue(label: "StateVersionClockTests", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var values: [UInt64] = []

        for _ in 0..<500 {
            group.enter()
            queue.async {
                let value = clock.next()
                lock.lock()
                values.append(value)
                lock.unlock()
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(Set(values), Set(1...500))
    }

    private func makeSnapshot() -> PlaybackSnapshot {
        PlaybackSnapshot(
            version: 12,
            trackID: "t1",
            queueRevision: 4,
            queue: [QueueItem(trackID: "t1", albumID: "a1", mediaRef: .native(relativePath: "Music/a1/t1.flac"))],
            queueIndex: 0,
            position: 42.25,
            intent: .paused,
            replayGainMode: .off,
            replayGainPreampDB: 0,
            masterVolume: 1,
            eqEnabled: false,
            eqBands: [],
            route: nil,
            sourceFormat: nil,
            outputFormat: nil,
            timestamp: Date(timeIntervalSince1970: 100)
        )
    }
}
