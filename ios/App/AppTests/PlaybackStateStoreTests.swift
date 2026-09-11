import XCTest
@testable import App

final class PlaybackStateStoreTests: XCTestCase {
    func testSaveCreatesParentDirectoryAndRoundTripsAtomically() throws {
        let baseURL = temporaryDirectory().appendingPathComponent("nested/state", isDirectory: true)
        let store = PlaybackStateStore(baseURL: baseURL)
        let snapshot = makeSnapshot(version: 7)

        try store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseURL.appendingPathComponent("transport-v1.json").path))
    }

    func testLoadRejectsIncompatibleSchema() throws {
        let baseURL = temporaryDirectory()
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(makeSnapshot(version: 1))) as? [String: Any])
        object["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: baseURL.appendingPathComponent("transport-v1.json"), options: .atomic)

        XCTAssertNil(PlaybackStateStore(baseURL: baseURL).load())
    }

    func testLoadRejectsMissingSchema() throws {
        let baseURL = temporaryDirectory()
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(makeSnapshot(version: 1))) as? [String: Any])
        object.removeValue(forKey: "schemaVersion")
        try JSONSerialization.data(withJSONObject: object).write(to: baseURL.appendingPathComponent("transport-v1.json"), options: .atomic)

        XCTAssertNil(PlaybackStateStore(baseURL: baseURL).load())
    }

    func testLoadRejectsCorruptDataWithoutChangingIt() throws {
        let baseURL = temporaryDirectory()
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let url = baseURL.appendingPathComponent("transport-v1.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)

        XCTAssertNil(PlaybackStateStore(baseURL: baseURL).load())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testSaveAtomicallyReplacesExistingSnapshot() throws {
        let baseURL = temporaryDirectory()
        let store = PlaybackStateStore(baseURL: baseURL)
        try store.save(makeSnapshot(version: 1))

        try store.save(makeSnapshot(version: 2))

        XCTAssertEqual(store.load()?.version, 2)
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: baseURL.path)
        XCTAssertEqual(siblingNames, ["transport-v1.json"])
    }

    func testDiagnosticsAreBoundedByCountAndPersistAsJSONLines() throws {
        let url = temporaryDirectory().appendingPathComponent("logs/audio.jsonl")
        let log = DiagnosticsLog(url: url, maxEntryCount: 2, maxByteCount: 4_096)
        try log.record(eventCode: "ONE", trackID: "t1")
        try log.record(eventCode: "TWO", trackID: "t2")
        try log.record(eventCode: "THREE", trackID: "t3")

        XCTAssertEqual(log.entries().map(\.eventCode), ["TWO", "THREE"])
        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertNoThrow(try lines.forEach { _ = try JSONDecoder().decode(DiagnosticEntry.self, from: Data($0.utf8)) })
    }

    func testDiagnosticsAreBoundedByUTF8Bytes() throws {
        let url = temporaryDirectory().appendingPathComponent("audio.jsonl")
        let log = DiagnosticsLog(url: url, maxEntryCount: 20, maxByteCount: 300)
        for index in 0..<10 {
            try log.record(eventCode: "EVENT_\(index)", trackID: String(repeating: "x", count: 80))
        }

        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 300)
        let data = try Data(contentsOf: url)
        for line in data.split(separator: 0x0A) {
            XCTAssertNoThrow(try JSONDecoder().decode(DiagnosticEntry.self, from: Data(line)))
        }
    }

    func testDiagnosticsSanitizeAbsolutePathsButRetainExtension() throws {
        let url = temporaryDirectory().appendingPathComponent("audio.jsonl")
        let log = DiagnosticsLog(url: url)
        try log.record(eventCode: "SOURCE_OPENED", trackID: "t1", filePath: "/private/mobile/Music/secret/album.flac")

        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("/private/mobile"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertEqual(log.entries().first?.fileExtension, "flac")
    }

    func testDiagnosticsCentrallySanitizeEveryStringField() throws {
        let url = temporaryDirectory().appendingPathComponent("audio.jsonl")
        let log = DiagnosticsLog(url: url)
        let route = RouteDescriptor(kind: .usb, name: "/private/device-name", sampleRate: 96_000, channelCount: 2)
        let source = SourceFormatDescriptor(codec: "file:///private/codec", container: "/private/container", sampleRate: nil, channelCount: nil, bitDepth: nil, duration: nil)
        try log.record(eventCode: "failed at /private/EVENT", trackID: #"C:\Users\listener\t1"#, sourceFormat: source, route: route)

        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("/private"))
        XCTAssertFalse(text.contains("file://"))
        XCTAssertFalse(text.contains("Users"))
    }

    func testDiagnosticsCanonicalizeRouteAndFormatText() throws {
        let url = temporaryDirectory().appendingPathComponent("audio.jsonl")
        let log = DiagnosticsLog(url: url)
        let route = RouteDescriptor(kind: .bluetooth, name: "Alice's AirPods with secret label", sampleRate: 48_000, channelCount: 2)
        let source = SourceFormatDescriptor(codec: "FLAC", container: "hostile free text", sampleRate: 96_000, channelCount: 2, bitDepth: 24, duration: 3)
        try log.record(eventCode: "SOURCE_OPENED", sourceFormat: source, route: route)

        let entry = try XCTUnwrap(log.entries().first)
        XCTAssertEqual(entry.route?.name, "bluetooth")
        XCTAssertEqual(entry.sourceFormat?.codec, "flac")
        XCTAssertNil(entry.sourceFormat?.container)
        XCTAssertFalse(try String(contentsOf: url).contains("Alice"))
        XCTAssertFalse(try String(contentsOf: url).contains("hostile"))
    }

    func testDiagnosticsInitRewritesLoadedContentSanitizedAndBounded() throws {
        let url = temporaryDirectory().appendingPathComponent("audio.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hostile = DiagnosticEntry.fixture(eventCode: "/private/event", trackID: "/private/track")
        let encoder = JSONEncoder()
        let original = (0..<5).map { _ in try! encoder.encode(hostile) + Data([0x0A]) }.reduce(Data(), +)
        try original.write(to: url)

        let log = DiagnosticsLog(url: url, maxEntryCount: 2, maxByteCount: 4_096)

        XCTAssertEqual(log.entries().count, 2)
        let persisted = try String(contentsOf: url)
        XCTAssertEqual(persisted.split(separator: "\n").count, 2)
        XCTAssertFalse(persisted.contains("/private"))
    }

    func testDiagnosticsInitRewritesLoadedContentToByteLimit() throws {
        let url = temporaryDirectory().appendingPathComponent("audio.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = DiagnosticEntry.fixture(eventCode: "ENGINE_START", trackID: String(repeating: "x", count: 200))
        let encoded = try JSONEncoder().encode(entry) + Data([0x0A])
        try (encoded + encoded).write(to: url)

        let log = DiagnosticsLog(url: url, maxEntryCount: 10, maxByteCount: 1)

        XCTAssertTrue(log.entries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testDiagnosticsFailedWriteLeavesRingUnchanged() throws {
        let parentFile = temporaryDirectory().appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: parentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("file".utf8).write(to: parentFile)
        let log = DiagnosticsLog(url: parentFile.appendingPathComponent("audio.jsonl"))

        XCTAssertThrowsError(try log.record(eventCode: "ENGINE_START"))
        XCTAssertTrue(log.entries().isEmpty)
    }

    func testDiagnosticsZeroBoundsPersistAnEmptyValidJSONLinesFile() throws {
        let url = temporaryDirectory().appendingPathComponent("audio.jsonl")
        let log = DiagnosticsLog(url: url, maxEntryCount: 0, maxByteCount: 0)

        try log.record(eventCode: "ENGINE_START")

        XCTAssertTrue(log.entries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeSnapshot(version: UInt64) -> PlaybackSnapshot {
        PlaybackSnapshot(
            version: version, trackID: "t1", queueRevision: 1,
            queue: [QueueItem(trackID: "t1", albumID: "a1", mediaRef: .legacyBlob(trackID: "t1"))],
            queueIndex: 0, position: 0, intent: .paused, replayGainMode: .off,
            replayGainPreampDB: 0, masterVolume: 1, eqEnabled: false, eqBands: [],
            route: nil, sourceFormat: nil, outputFormat: nil,
            timestamp: Date(timeIntervalSince1970: 100)
        )
    }
}

private extension DiagnosticEntry {
    static func fixture(eventCode: String, trackID: String?) -> DiagnosticEntry {
        let data = Data("""
        {"timestamp":0,"eventCode":"\(eventCode)","trackID":"\(trackID ?? "")","sourceFormat":null,"outputFormat":null,"route":null,"recoverable":null,"fileExtension":null}
        """.utf8)
        return try! JSONDecoder().decode(DiagnosticEntry.self, from: data)
    }
}
