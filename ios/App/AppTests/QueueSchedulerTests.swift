import AVFoundation
import XCTest
@testable import App

final class QueueSchedulerTests: XCTestCase {
    private let a = QueueItem(trackID: "a", albumID: "album", mediaRef: .native(relativePath: "a.wav"))
    private let b = QueueItem(trackID: "b", albumID: "album", mediaRef: .native(relativePath: "b.wav"))
    private let c = QueueItem(trackID: "c", albumID: "album", mediaRef: .native(relativePath: "c.wav"))

    func testQueueReplacementInvalidatesPreviouslyPreparedNextTrack() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.prepareCurrent(position: 0)
        let old = scheduler.currentGeneration
        let completion = try XCTUnwrap(graph.schedules.first?.completion)
        try scheduler.replaceQueue([a, c], index: 0, revision: 2)
        completion()
        XCTAssertGreaterThan(scheduler.currentGeneration, old)
        XCTAssertEqual(scheduler.preparedNextTrackID, "c")
        XCTAssertEqual(scheduler.currentTrackID, "a")
        XCTAssertEqual(scheduler.queueRevision, 2)
    }

    func testNextIsScheduledAtExactOutputBoundaryBeforePlaybackStarts() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.prepareCurrent(position: 0)
        XCTAssertFalse(graph.started)
        XCTAssertEqual(graph.schedules.map { $0.slot }, [.a, .b])
        XCTAssertEqual(graph.schedules.map { $0.outputFrame }, [0, 2401])
        try scheduler.play()
        XCTAssertTrue(scheduler.isPlaying)
        XCTAssertTrue(graph.started)
        XCTAssertEqual(graph.schedules.count, 2)
    }

    func testHandoffFlipsSlotsAndPreparesFollowingWithoutAnotherPlayCommand() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b, c])
        try scheduler.play()
        let first = graph.schedules[0].completion
        first()
        XCTAssertEqual(scheduler.currentTrackID, "b") // Drains serialized completion.
        XCTAssertEqual(scheduler.currentSlot, .b)
        XCTAssertEqual(scheduler.preparedNextTrackID, "c")
        XCTAssertEqual(graph.schedules.last?.slot, .a)
        XCTAssertEqual(graph.schedules.last?.outputFrame, 4802)
        first() // A duplicated callback from this generation must also be harmless.
        XCTAssertEqual(scheduler.currentTrackID, "b")
    }

    func testRapidSkipAndPreviousRejectAllObsoleteCompletions() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b, c])
        try scheduler.play()
        let staleA = graph.schedules[0].completion
        try scheduler.next()
        let staleB = graph.schedules[2].completion
        try scheduler.next()
        staleA()
        staleB()
        XCTAssertEqual(scheduler.currentTrackID, "c")
        try scheduler.previous()
        XCTAssertEqual(scheduler.currentTrackID, "b")
        XCTAssertTrue(scheduler.isPlaying)
    }

    func testSeekCancelsOldScheduleAndUsesRemainingDecodedFrames() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        let stale = graph.schedules[0].completion
        try scheduler.seek(seconds: 1000.0 / 48000)
        stale()
        XCTAssertEqual(scheduler.currentTrackID, "a")
        XCTAssertEqual(graph.schedules.suffix(2).map { $0.sourceFrame }, [1000, 0])
        XCTAssertEqual(graph.schedules.last?.outputFrame, 1401)
        XCTAssertTrue(scheduler.isPlaying)
    }

    func testPauseResumeReanchorsBothSlotsAndPreservesPosition() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        let stale = graph.schedules[0].completion
        graph.elapsedFrames = 1000
        scheduler.pause()
        stale()
        XCTAssertFalse(scheduler.isPlaying)
        try scheduler.play()
        XCTAssertEqual(graph.schedules.suffix(2).map { $0.sourceFrame }, [1000, 0])
        XCTAssertEqual(graph.schedules.last?.outputFrame, 1401)
    }

    func testInvalidationStopsPreparedPlayersAndRejectsCallbacks() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        let callback = graph.schedules[0].completion
        scheduler.invalidatePendingSchedule()
        callback()
        XCTAssertEqual(scheduler.currentTrackID, "a")
        XCTAssertNil(scheduler.preparedNextTrackID)
        XCTAssertFalse(scheduler.isPlaying)
        XCTAssertFalse(graph.started)
    }

    func testCompletedEventIsEmittedOnlyOnceAndEndsPlayback() throws {
        let (scheduler, graph, _) = try makeScheduler([a])
        let completed = expectation(description: "completed once")
        completed.assertForOverFulfill = true
        scheduler.onEvent = { if case .completed = $0 { completed.fulfill() } }
        try scheduler.play()
        graph.schedules[0].completion()
        graph.schedules[0].completion()
        XCTAssertFalse(scheduler.isPlaying)
        wait(for: [completed], timeout: 1)
        XCTAssertNil(scheduler.preparedNextTrackID)
    }

    func testUnplayableNextIsReportedAndNeverSilentlySkipped() throws {
        let capabilities: [MediaCapability] = [.unsupported(reason: "decoder"), .decodeFailed(reason: "corrupt"), .unavailable]
        for capability in capabilities {
            let (scheduler, graph, _) = try makeScheduler([a, b, c], rejected: capability)
            let failed = expectation(description: "explicit media failure")
            scheduler.onEvent = { event in
                if case .failed(_, let error, _) = event {
                    XCTAssertEqual(error, .media(trackID: "b", capability: capability))
                    failed.fulfill()
                }
            }
            XCTAssertThrowsError(try scheduler.play())
            wait(for: [failed], timeout: 1)
            XCTAssertEqual(scheduler.currentTrackID, "a")
            XCTAssertNil(scheduler.preparedNextTrackID)
            XCTAssertFalse(graph.started)
        }
    }

    func testReleaseResolvedMediaOnReplacementAndFailure() throws {
        let (scheduler, _, resolver) = try makeScheduler([a, b])
        try scheduler.prepareCurrent(position: 0)
        try scheduler.replaceQueue([c], index: 0, revision: 2)
        XCTAssertEqual(resolver.released.map { $0.lastPathComponent }, ["a.wav", "b.wav"])
        scheduler.invalidatePendingSchedule()
        XCTAssertEqual(resolver.released.last?.lastPathComponent, "c.wav")
    }

    func testInvalidQueueAndSeekInputsAreRejected() throws {
        let (scheduler, _, _) = try makeScheduler([a])
        XCTAssertThrowsError(try scheduler.setQueue([a], index: 1, revision: 2))
        for position in [-1, Double.nan, Double.infinity, 1] {
            XCTAssertThrowsError(try scheduler.seek(seconds: position))
        }
        try scheduler.setQueue([], index: 0, revision: 3)
        XCTAssertNil(scheduler.currentTrackID)
        XCTAssertThrowsError(try scheduler.play())
    }

    func testExactPCMFixtureBoundaryHasZeroInsertedOrDuplicatedFrames() throws {
        let left = try pcm("gapless-a")
        let right = try pcm("gapless-b")
        XCTAssertEqual(left.count, 2401)
        XCTAssertEqual(right.count, 2399)
        let boundary = try QueueScheduler.outputBoundary(start: 0, sourceFrames: Int64(left.count), sourceRate: 48000, outputRate: 48000)
        XCTAssertEqual(boundary, 2401)
        var rendered = [Int16](repeating: 0, count: Int(boundary) + right.count)
        rendered.replaceSubrange(0..<left.count, with: left)
        rendered.replaceSubrange(Int(boundary)..<rendered.count, with: right)
        let expected = (0..<4800).map { frame in
            Int16((8192 * sin(2 * Double.pi * 440 * Double(frame) / 48000)).rounded(.toNearestOrEven))
        }
        XCTAssertEqual(rendered, expected) // Exact samples, 0 inserted / 0 duplicated PCM frames.
        XCTAssertEqual(try QueueScheduler.outputBoundary(start: 900, sourceFrames: 44100, sourceRate: 44100, outputRate: 48000), 48900)
        XCTAssertThrowsError(try QueueScheduler.outputBoundary(start: Int64.max, sourceFrames: 1, sourceRate: 48000, outputRate: 48000))
    }

    func testOutOfOrderNodeCompletionsDoNotLoseQueueCompletion() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        graph.schedules[1].completion()
        graph.schedules[0].completion()
        XCTAssertEqual(scheduler.currentTrackID, "b")
        XCTAssertFalse(scheduler.isPlaying)
    }

    func testOpeningNextFileFailureClosesCurrentAndReportsNextTrack() throws {
        let (scheduler, graph, resolver) = try makeScheduler([a, b, c])
        graph.failingFile = "b.wav"
        XCTAssertThrowsError(try scheduler.play()) { error in
            guard let failure = error as? QueueSchedulerError,
                  case .operation(let trackID, _) = failure else {
                return XCTFail("Expected operation failure")
            }
            XCTAssertEqual(trackID, "b")
        }
        XCTAssertFalse(scheduler.isPlaying)
        XCTAssertNil(scheduler.preparedNextTrackID)
        XCTAssertEqual(Set(resolver.released.map { $0.lastPathComponent }), Set(["a.wav", "b.wav"]))
    }

    func testResumeRetainsExactFrameWithoutFloatingPointRoundTrip() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        graph.elapsedFrames = 27 // 27 / 48000 * 48000 can round below 27.
        scheduler.pause()
        try scheduler.play()
        XCTAssertEqual(graph.schedules.suffix(2).first?.sourceFrame, 27)
    }

    func testPreparationFailureAfterHandoffStopsAndReportsFollowingTrack() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b, c])
        try scheduler.play()
        graph.failingFile = "c.wav"
        graph.schedules[0].completion()
        XCTAssertEqual(scheduler.currentTrackID, "b")
        XCTAssertFalse(scheduler.isPlaying)
        XCTAssertNil(scheduler.preparedNextTrackID)
    }

    func testPlaybackCanRestartAfterFinalCompletion() throws {
        let (scheduler, graph, _) = try makeScheduler([a])
        try scheduler.play()
        graph.schedules[0].completion()
        XCTAssertFalse(scheduler.isPlaying)
        try scheduler.play()
        XCTAssertTrue(scheduler.isPlaying)
        XCTAssertEqual(graph.schedules.last?.sourceFrame, 0)
    }

    /// Device integration gate: run explicitly on an idle 48 kHz output route.
    /// This exercises real AVAudioPlayerNodes and captures the actual program output.
    /// The pure PCM test above remains available without audio hardware.
    func testDeviceCaptureGaplessWAVHasExactBoundary() throws {
        guard ProcessInfo.processInfo.environment["AEON_RUN_AUDIO_CAPTURE"] == "1" else {
            throw XCTSkip("Set AEON_RUN_AUDIO_CAPTURE=1 on a device/simulator with a 48 kHz audio route")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setPreferredSampleRate(48000)
        try session.setActive(true)
        defer { try? session.setActive(false) }
        let graph = AudioEngineGraph()
        try graph.configure()
        guard try graph.schedulingSampleRate() == 48000 else {
            throw XCTSkip("Exact PCM gate requires a 48 kHz route; no codec/SRC tolerance is claimed")
        }
        let resolver = BundleResolver(bundle: Bundle(for: Self.self))
        let scheduler = QueueScheduler(graph: graph, resolver: resolver)
        let tracks = ["gapless-a", "gapless-b"].map {
            QueueItem(trackID: $0, albumID: "continuous", mediaRef: .native(relativePath: $0 + ".wav"))
        }
        let captured = expectation(description: "continuous PCM captured")
        let lock = NSLock()
        var samples: [Int16] = []
        var captureComplete = false
        graph.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let values = (0..<Int(buffer.frameLength)).map { frame in
                Int16(max(-32768, min(32767, (Double(channel[frame]) * 32768).rounded())))
            }
            lock.lock()
            if !captureComplete {
                samples.append(contentsOf: values)
                if let first = samples.firstIndex(where: { $0 != 0 }), first > 0,
                   samples.count >= first - 1 + 4800 {
                    captureComplete = true
                    captured.fulfill()
                }
            }
            lock.unlock()
        }
        defer {
            scheduler.invalidatePendingSchedule()
            graph.engine.mainMixerNode.removeTap(onBus: 0)
            graph.stop()
        }
        try scheduler.setQueue(tracks, index: 0, revision: 1)
        try scheduler.play()
        wait(for: [captured], timeout: 5)
        lock.lock()
        let output = samples
        lock.unlock()
        let first = try XCTUnwrap(output.firstIndex(where: { $0 != 0 }))
        XCTAssertGreaterThan(first, 0)
        guard first > 0, output.count >= first - 1 + 4800 else { return XCTFail("Incomplete PCM capture") }
        let expected = try pcm("gapless-a") + pcm("gapless-b")
        XCTAssertEqual(Array(output[(first - 1)..<(first - 1 + 4800)]), expected)
    }

    private func pcm(_ name: String) throws -> [Int16] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "wav", subdirectory: "audio"))
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.int16ChannelData)[0], count: Int(buffer.frameLength)))
    }

    private func makeScheduler(_ items: [QueueItem], rejected: MediaCapability? = nil) throws -> (QueueScheduler, RecordingGraph, FixtureResolver) {
        let graph = RecordingGraph()
        let resolver = FixtureResolver()
        let scheduler = QueueScheduler(graph: graph, resolver: resolver, probe: { url in
            if url.lastPathComponent == "b.wav", let rejected { return rejected }
            return .playable(ProbedMedia(url: url, descriptor: SourceFormatDescriptor(codec: "pcm", container: "wav", sampleRate: 48000, channelCount: 2, bitDepth: 16, duration: 2401.0 / 48000), frameCount: 2401))
        })
        try scheduler.setQueue(items, index: 0, revision: 1)
        return (scheduler, graph, resolver)
    }
}

private final class FixtureResolver: MediaResolving {
    var released: [URL] = []
    func resolve(_ reference: MediaReference) throws -> URL {
        guard case .native(let path) = reference else { throw MediaStoreError.invalidBookmark }
        return URL(fileURLWithPath: "/fixtures/\(path)")
    }
    func release(_ url: URL) { released.append(url) }
}

private final class RecordingGraph: QueueSchedulingGraph {
    struct Schedule {
        let slot: AudioSlot
        let sourceFrame: Int64
        let outputFrame: Int64
        let completion: () -> Void
    }
    var schedules: [Schedule] = []
    var started = false
    var elapsedFrames: Int64 = 0
    var failingFile: String?
    func schedulingSampleRate() throws -> Double { 48000 }
    func openForScheduling(url: URL, slot: AudioSlot) throws -> ScheduledAudioFile {
        if url.lastPathComponent == failingFile { throw MediaStoreError.verificationFailed }
        return ScheduledAudioFile(frameCount: 2401, sampleRate: 48000)
    }
    func schedule(slot: AudioSlot, sourceFrame: Int64, outputFrame: Int64, completion: @escaping () -> Void) throws {
        schedules.append(Schedule(slot: slot, sourceFrame: sourceFrame, outputFrame: outputFrame, completion: completion))
    }
    func startScheduledPlayback() throws { started = true }
    func elapsedSourceFrames(slot: AudioSlot) -> Int64? { elapsedFrames }
    func cancelScheduledPlayback() { started = false; elapsedFrames = 0 }
    func closeScheduledFile(slot: AudioSlot) {}
}

private final class BundleResolver: MediaResolving {
    let bundle: Bundle
    init(bundle: Bundle) { self.bundle = bundle }
    func resolve(_ reference: MediaReference) throws -> URL {
        guard case .native(let path) = reference,
              let url = bundle.url(forResource: path, withExtension: nil, subdirectory: "audio") else {
            throw MediaStoreError.verificationFailed
        }
        return url
    }
}
